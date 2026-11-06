# typed: strict
# frozen_string_literal: true

module LiveStreams
  # Where a YouTube live stream is read from (PROPOSAL §7.8). Its link is a
  # page, not something ffmpeg can open, so yt-dlp asks YouTube for the
  # stream's HLS playlists — the picture's and the sound's apart, as YouTube
  # serves them. Those addresses expire (six hours on), so they're kept in
  # Rails.cache until a while before, shared by the probe, the stills and
  # the transcoder's relay, and forgotten when a relay fails on them.
  module YoutubeSource
    extend T::Sig

    # Used no closer to its expiry than this: a relay started on it has
    # that long before YouTube stops answering it and it reconnects.
    MARGIN = T.let(30.minutes, ActiveSupport::Duration)
    LONGEST = T.let(5.hours, ActiveSupport::Duration)

    sig { params(stream: LiveStream).returns(Resolved) }
    def self.resolve(stream)
      cached = Rails.cache.read(cache_key(stream))
      return Resolved.new(video: cached.fetch("video"), audio: cached["audio"]) if cached.is_a?(Hash)

      # Built again from the id, never the stored text as is (CLAUDE.md
      # invariant 6).
      urls = Youtube::YtDlp.live_urls(Youtube::Urls.live_url(stream.url.to_s))
      raise Prober::Failure, "#{stream.name} isn't live on YouTube right now" if urls.empty?

      resolved = Resolved.new(video: urls.fetch(0), audio: urls[1])
      keep = expires_in(urls)
      Rails.cache.write(cache_key(stream), { "video" => resolved.video, "audio" => resolved.audio }, expires_in: keep) if keep
      resolved
    rescue Youtube::Urls::Invalid => e
      raise Prober::Failure, e.message
    rescue Youtube::YtDlp::Error => e
      raise Prober::Failure, explain(stream, e.message)
    end

    sig { params(stream: LiveStream).void }
    def self.forget(stream) = Rails.cache.delete(cache_key(stream))

    # What yt-dlp said, as Settings and the player say it.
    sig { params(stream: LiveStream, message: String).returns(String) }
    def self.explain(stream, message)
      case message
      when /not currently live|is not live|offline/i then "#{stream.name} isn't live on YouTube right now"
      when /private video/i then "That YouTube video is private"
      when /unavailable|does not exist|removed/i then "YouTube says that video isn't available"
      when /sign in|not a bot|age.restricted|inappropriate/i then "YouTube wants a sign-in to play #{stream.name}"
      else "YouTube didn't give a stream: #{stream.redact(message)}"
      end
    end

    sig { params(stream: LiveStream).returns(String) }
    def self.cache_key(stream) = "live_streams/youtube/#{stream.id}/#{Digest::SHA256.hexdigest(stream.url.to_s).first(16)}"

    # Until the first of the playlists expires, less the margin; nil when
    # that's already too close to be worth keeping.
    sig { params(urls: T::Array[String]).returns(T.nilable(ActiveSupport::Duration)) }
    def self.expires_in(urls)
      expiries = urls.filter_map { |url| url[%r{/expire/(\d+)}, 1]&.to_i }
      return nil if expiries.empty?

      seconds = expiries.min.to_i - Time.current.to_i - MARGIN.to_i
      seconds.positive? ? [ seconds.seconds, LONGEST ].min : nil
    end
    private_class_method :cache_key, :expires_in
  end
end
