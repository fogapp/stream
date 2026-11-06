# typed: strict
# frozen_string_literal: true

module LiveStreams
  # Where an MLB.tv game is read from (PROPOSAL §7.8). yt-dlp signs in with
  # the household's account and lists every broadcast of the game — home and
  # away, TV and radio, English and Spanish — each as HLS formats named like
  # "Home-TV-en-6600". The names' case and shape have changed between
  # yt-dlp versions, so the broadcast is picked here, from what each format
  # says it is, not by asking yt-dlp for a name. The playlists carry a token
  # MLB.tv doesn't say the life of, so they're kept a short while and
  # forgotten when a relay fails on them, as YouTube's are. A team's stream
  # finds its game in MLB's schedule first, and plays the team's own
  # broadcast of it.
  module MlbSource
    extend T::Sig

    KEEP = T.let(20.minutes, ActiveSupport::Duration)

    sig { params(stream: LiveStream).returns(Resolved) }
    def self.resolve(stream)
      cached = Rails.cache.read(cache_key(stream))
      return Resolved.new(video: cached.fetch("video"), audio: cached["audio"], user_agent: cached["user_agent"]) if cached.is_a?(Hash)

      setting = MlbSetting.unscoped.find_by(household_id: stream.household_id)
      raise Prober::Failure, "Sign in to MLB.tv in Settings › Integrations first" if setting.nil?

      url, feed = game_of(stream)
      info = signed_in(setting) { |args| Youtube::YtDlp.info(url, args) }
      raise Prober::Failure, "#{stream.name} isn't live on MLB.tv right now" unless info.data["is_live"]

      resolved = pick(Array(info.data["formats"]), feed)
      raise Prober::Failure, explain(stream, info.warnings.join("; ")) if resolved.nil?

      Rails.cache.write(cache_key(stream),
        { "video" => resolved.video, "audio" => resolved.audio, "user_agent" => resolved.user_agent }, expires_in: KEEP)
      resolved
    rescue Mlb::Urls::Invalid, Mlb::Schedule::Error => e
      raise Prober::Failure, e.message
    rescue Youtube::YtDlp::Error => e
      raise Prober::Failure, explain(stream, e.message)
    end

    # The game's link and which broadcast of it: an added stream's own; a
    # team's game on now, from the team's side.
    sig { params(stream: LiveStream).returns([ String, LiveStream::Feed ]) }
    def self.game_of(stream)
      team_id = stream.mlb_team_id
      return [ Mlb::Urls.game_url(stream.url.to_s), stream.feed_enum || LiveStream::Feed::Home ] if team_id.nil?

      game = Mlb::Schedule.new.watchable_game(team_id)
      raise Prober::Failure, "The #{stream.name} aren't playing on MLB.tv right now" if game.nil?

      [ Mlb::Urls.for_game(Mlb::Game.game_pk(game)), Mlb::Game.side(game, team_id) ]
    end

    sig { params(stream: LiveStream).void }
    def self.forget(stream) = Rails.cache.delete(cache_key(stream))

    # The preferred feed's TV broadcast, else the other's, else any (a
    # national broadcast has neither); English over another language; the
    # highest bitrate. Sound sent apart comes from the same broadcast. The
    # playlists are read with the User-Agent yt-dlp read them with: MLB.tv's
    # CDN refuses ffmpeg's.
    sig { params(formats: T::Array[T.untyped], feed: LiveStream::Feed).returns(T.nilable(Resolved)) }
    def self.pick(formats, feed)
      formats = formats.select { |format| format.is_a?(Hash) && format["url"].to_s.start_with?("https://") && format["protocol"].to_s.start_with?("m3u8") }
      video = formats.select { |format| format["vcodec"] != "none" && !radio?(format) }
        .max_by { |format| [ feed_rank(format, feed), english?(format) ? 1 : 0, format["tbr"].to_f, format["height"].to_i ] }
      return nil if video.nil?

      agent = user_agent_of(video)
      return Resolved.new(video: video.fetch("url"), user_agent: agent) unless video["acodec"] == "none"

      broadcast = broadcast_of(video)
      audio = formats.select { |format| format["vcodec"] == "none" && broadcast_of(format) == broadcast }
        .max_by { |format| [ english?(format) ? 1 : 0, format["abr"].to_f, format["tbr"].to_f ] }
      Resolved.new(video: video.fetch("url"), audio: audio&.fetch("url"), user_agent: agent)
    end

    # The User-Agent in the headers yt-dlp says a format is fetched with
    # (http_headers), whichever way it capitalizes it.
    sig { params(format: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def self.user_agent_of(format)
      headers = format["http_headers"]
      return nil unless headers.is_a?(Hash)

      value = headers.find { |name, _| name.to_s.casecmp?("user-agent") }&.last
      value.is_a?(String) && value.present? ? value : nil
    end

    # What yt-dlp or MLB.tv said, as Settings and the player say it.
    sig { params(stream: LiveStream, message: String).returns(String) }
    def self.explain(stream, message)
      case message
      when /invalid username or password|login required|registered users/i
        "MLB.tv didn't accept the account in Settings › Integrations"
      when /black(ed)?.?out/i then "#{stream.name} is blacked out on MLB.tv where this server is"
      when /entitle|not authori[sz]ed|subscription/i then "The MLB.tv account doesn't include #{stream.name}"
      when "", /no (video )?formats/i then "MLB.tv has no TV broadcast of #{stream.name} right now"
      else "MLB.tv didn't give a stream: #{stream.redact(message)}"
      end
    end

    # yt-dlp's sign-in, from a netrc file only it can read and only for as
    # long as it runs: a password on its command line would be in every
    # process listing.
    sig { params(setting: MlbSetting, block: T.proc.params(args: T::Array[String]).returns(Youtube::YtDlp::Info)).returns(Youtube::YtDlp::Info) }
    def self.signed_in(setting, &block)
      Dir.mktmpdir("stream-mlb") do |directory|
        netrc = File.join(directory, "netrc")
        File.open(netrc, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("machine mlb login #{netrc_word(setting.username)} password #{netrc_word(setting.password.to_s)}\n")
        end
        block.call([ "--netrc", "--netrc-location", netrc ])
      end
    end

    # Quoted, so a password's spaces and # survive Python's netrc reader.
    sig { params(word: String).returns(String) }
    def self.netrc_word(word) = %("#{word.gsub(/["\\]/) { |character| "\\#{character}" }}")

    sig { params(format: T::Hash[String, T.untyped], feed: LiveStream::Feed).returns(Integer) }
    def self.feed_rank(format, feed)
      case broadcast_of(format).first
      when feed.serialize then 2
      when *LiveStream::Feed.values.map(&:serialize) then 1
      else 0
      end
    end

    # [feed, medium], lowercased, from the id yt-dlp gives every format of
    # a broadcast ("Home-TV-en-6600", and its sound "Home-TV-en-audio-…").
    sig { params(format: T::Hash[String, T.untyped]).returns([ String, String ]) }
    def self.broadcast_of(format)
      words = format["format_id"].to_s.split("-")
      [ words[0].to_s.downcase, words[1].to_s.downcase ]
    end

    sig { params(format: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.radio?(format) = broadcast_of(format).last == "audio"

    sig { params(format: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.english?(format) = format["language"].to_s.downcase.start_with?("en")

    sig { params(stream: LiveStream).returns(String) }
    def self.cache_key(stream) = "live_streams/mlb/#{stream.id}/#{stream.feed}/#{Digest::SHA256.hexdigest(stream.url.to_s).first(16)}"

    private_class_method :game_of, :signed_in, :netrc_word, :user_agent_of, :feed_rank, :broadcast_of, :radio?, :english?, :cache_key
  end
end
