# typed: strict
# frozen_string_literal: true

module PlaybackSessionSerializer
  extend T::Sig

  # Everything from the session's stored decision: a session already made
  # answers with what it was decided, never with what it'd be decided now.
  sig { params(session: PlaybackSession, token: String, resume_at: Float).returns(T::Hash[Symbol, T.untyped]) }
  def self.session_json(session, token:, resume_at:)
    decision = session.stored_decision
    file = session.media_file
    direct = !session.method_enum.streamed?
    ext = session.method_enum == PlaybackSession::Method::Optimized ? "mp4" : File.extname(file&.path.to_s).delete(".").downcase
    base = "/media/s/#{token}"
    {
      id: session.id, method: session.method_enum, profile_id: session.profile_id,
      **heading(session.playable), **game_heading(session),
      source: source_json(session, base, direct, ext, decision),
      progress_url: "#{base}/progress",
      events_url: "#{base}/events",
      audio_stream_index: session.audio_stream_index,
      subtitles: file ? Subtitles::Tracks.for(file).map { |track| subtitle_json(track, base) } : [],
      # The picture subtitle drawn into this stream, if one is.
      burned_subtitle: (index = session.burned_subtitle) ? "e#{index}" : nil,
      fonts: file ? Subtitles::Extractor.fonts(file).map { |font| "#{base}/fonts/#{font.basename}" } : [],
      chapters: session.playable.is_a?(Video) ? Channels::Catalog.chapters(session.playable, file) : file&.chapters || [],
      markers: MarkerSerializer.list(file),
      skip: skip_json(session),
      next_up: session.airing_id ? nil : next_up_json(session),
      live: live_json(session),
      live_stream: live_stream_json(session),
      segments: segments_json(session),
      playlist_id: session.playlist_id,
      up_next_seconds: session.profile&.up_next_seconds || UP_NEXT_SECONDS,
      # Episodes in a row before "Still watching?"; 0 never asks.
      still_watching_after: session.profile&.still_watching_after || STILL_WATCHING_AFTER,
      loudness: file&.loudness_lufs && { integrated: file.loudness_lufs, true_peak: file.true_peak_dbfs },
      trickplay: trickplay_json(file&.trickplay, base),
      decision: { summary: decision.summary, video: decision.video, audio: decision.audio },
      # The file's share can't deliver it as fast as it plays: the player
      # says so rather than leave the pauses to explain themselves.
      falls_behind: falls_behind?(session),
      # Carried on from a session that failed, a rung down:
      # what it fell from, and whether to
      # try climbing back at the next seek.
      fallback: fallback_json(session),
      resume_at: resume_at.round(1),
      duration_seconds: file&.duration_seconds,
      # For frame-stepping (, and .).
      frame_rate: file&.primary_video&.frame_rate,
      media_file: file && {
        id: file.id, filename: file.filename,
        audio: file.media_streams.select { |s| s.kind_enum == MediaStream::Kind::Audio }.map { |s| track_json(s) },
        subtitles: file.media_streams.select { |s| s.kind_enum == MediaStream::Kind::Subtitle }.map { |s| track_json(s) }
      }
    }
  end

  # An optimized version is read from `cache`, not the share.
  sig { params(session: PlaybackSession).returns(T::Boolean) }
  def self.falls_behind?(session)
    return false if session.standby || session.method_enum == PlaybackSession::Method::Optimized

    Playback::Pace.for(session, converting: true).falls_behind?
  end

  sig { params(session: PlaybackSession).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.fallback_json(session)
    stored = session.stored_decision
    fell = stored.fallback
    fell && { from_method: fell["from"], failure_class: fell["failure"], upgradable: stored.transient_fallback? }
  end

  sig do
    params(session: PlaybackSession, base: String, direct: T::Boolean, ext: String, decision: Playback::StoredDecision)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.source_json(session, base, direct, ext, decision)
    hls = "application/vnd.apple.mpegurl"
    return { kind: "hls", url: "#{base}/live/index.m3u8", mime_type: hls } if session.playable.is_a?(LiveStream)
    return { kind: "file", url: "#{base}/original.#{ext}", mime_type: decision.direct_mime_type } if direct

    { kind: "hls", url: "#{base}/hls/index.m3u8", mime_type: hls }
  end

  # A camera or web stream (PROPOSAL §7.8): what it is, and how far back
  # its relay lets a viewer go.
  sig { params(session: PlaybackSession).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.live_stream_json(session)
    stream = session.playable
    return nil unless stream.is_a?(LiveStream)

    { id: stream.id, name: stream.name, kind: stream.kind_enum, library_id: stream.library_id }
  end

  # A game on a Grid channel is called by its matchup, not its team's stream.
  sig { params(session: PlaybackSession).returns(T::Hash[Symbol, T.untyped]) }
  def self.game_heading(session)
    airing = session.airing
    return {} unless airing&.game?

    { title: airing.program_title.to_s, subtitle: airing.program_subtitle || "MLB.tv" }
  end

  # Tuned in on a Grid channel (PROPOSAL §7.7): which airing, when it
  # runs, and the server's clock, so the player knows where "live" is
  # whatever the device's own clock says.
  sig { params(session: PlaybackSession).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.live_json(session)
    airing = session.airing
    station = airing&.station
    return nil if airing.nil? || station.nil?

    # What follows, as the schedule has it now: the player readies it as
    # this one nears its end, and knows how long a gap's slate lasts.
    following = airing.following
    {
      station_id: station.id, number: station.number, name: station.name, airing_id: airing.id,
      starts_at: airing.starts_at.iso8601(3), ends_at: airing.ends_at.iso8601(3), server_now: Time.current.iso8601(3),
      # A part of a program broken for breaks: where in the file it runs.
      media_start: airing.media_start, media_end: airing.media_end,
      next_airing_id: following&.id, next_starts_at: following&.starts_at&.iso8601(3)
    }
  end

  # What the player's top bar says, and where Back goes.
  sig { params(playable: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
  def self.heading(playable)
    case playable
    when Movie
      { title: playable.title, subtitle: playable.year&.to_s, back_path: "/movie/#{playable.id}" }
    when Episode
      { title: playable.show&.title.to_s, subtitle: [ playable.code, playable.title ].compact.join(" · "),
        back_path: "/show/#{playable.show_id}?season=#{playable.season_number}", show_id: playable.show_id,
        season_number: playable.season_number }
    when Video
      { title: playable.title, subtitle: playable.channel&.title, back_path: "/video/#{playable.id}" }
    when LiveStream
      { title: playable.name, subtitle: playable.description.presence&.truncate(80) || playable.kind_enum.label,
        back_path: playable.team? ? "/baseball" : "/library/#{playable.library_id}" }
    when Clip
      { title: playable.title, subtitle: [ I18n.l(playable.captured_at.to_date, format: :long), playable.city ].compact.join(" · "),
        back_path: "/clip/#{playable.id}" }
    when Extra
      owner = playable.owner
      back = case owner
      when Movie then "/movie/#{owner.id}"
      when Show then "/show/#{owner.id}"
      when Season then "/show/#{owner.show_id}?season=#{owner.season_number}"
      else "/"
      end
      { title: playable.title, subtitle: [ playable.kind_label, owner.try(:title) || owner.try(:show)&.title ].compact.join(" · "),
        back_path: back }
    else
      { title: "", subtitle: nil, back_path: "/" }
    end
  end

  # SponsorBlock segments, each with what this profile does about it.
  sig { params(session: PlaybackSession).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.segments_json(session)
    video = session.playable
    profile = session.profile
    return [] unless video.is_a?(Video) && profile

    actions = SponsorSegment.actions_for(profile)
    video.sponsor_segments.map do |segment|
      category = segment.category_enum.serialize
      { category: category, start: segment.start_seconds, end: segment.end_seconds, action: actions.fetch(category, "ask") }
    end
  end

  # How long the Up next card counts down, unless the profile says otherwise.
  UP_NEXT_SECONDS = 10
  STILL_WATCHING_AFTER = 3

  sig { params(session: PlaybackSession).returns(T::Hash[Symbol, T::Boolean]) }
  def self.skip_json(session) = skip_for(session.profile, session.playable)

  # What this profile always skips here: its own choice for every show, or
  # this show's.
  sig { params(profile: T.nilable(Profile), episode: T.untyped).returns(T::Hash[Symbol, T::Boolean]) }
  def self.skip_for(profile, episode)
    preference = episode.is_a?(Episode) && profile ? ShowPreference.find_by(profile_id: profile.id, show_id: episode.show_id) : nil
    {
      intro: profile&.always_skip_intro || preference&.skip_intro || false, recap: preference&.skip_recap || false,
      credits: profile&.always_skip_credits || preference&.skip_credits || false
    }
  end

  # What plays next: the session's playlist's next item, or its episode's.
  sig { params(session: PlaybackSession).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.next_up_json(session)
    playlist = session.playlist
    return playlist_next_json(playlist, session.playable) if playlist

    episode = session.playable
    return nil unless episode.is_a?(Episode)

    show = episode.show
    nxt = following_episode(episode)
    return nil if nxt.nil? || show.nil?

    images = ArtworkSerializer.index([ nxt, show ])
    picture = ArtworkSerializer.images(images, nxt).values_at("still", "thumb").compact.first ||
      ArtworkSerializer.images(images, show)["backdrop"]
    { kind: "episode", id: nxt.id, code: nxt.code, title: nxt.title, show_title: show.title, image: picture, playlist_id: nil }
  end

  # The episode after this one that has a file, into the next season if
  # need be; specials only follow specials.
  sig { params(episode: Episode).returns(T.nilable(Episode)) }
  def self.following_episode(episode)
    show = episode.show
    return nil if show.nil?

    Viewing::NextUp.available(show).to_a.find do |candidate|
      same_kind = episode.season_number.zero? == candidate.season_number.zero?
      later = [ candidate.season_number, candidate.episode_number.to_i ] <=> [ episode.season_number, episode.episode_number.to_i ]
      same_kind && later.to_i.positive?
    end
  end

  # In a playlist, what's next is the playlist's next item, movie or episode.
  sig { params(playlist: Playlist, current: T.untyped).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.playlist_next_json(playlist, current)
    nxt = playlist.after(current)
    return nil if nxt.nil?

    show = nxt.is_a?(Episode) ? nxt.show : nil
    images = ArtworkSerializer.index([ nxt, show ].compact)
    own = ArtworkSerializer.images(images, nxt)
    picture = own.values_at("still", "backdrop", "thumb").compact.first || (show && ArtworkSerializer.images(images, show)["backdrop"])
    {
      kind: nxt.class.name.to_s.downcase, id: nxt.id, code: nxt.is_a?(Episode) ? nxt.code : nil,
      title: nxt.title, show_title: show&.title || (nxt.is_a?(Video) ? nxt.channel&.title : nil), image: picture,
      playlist_id: playlist.id
    }
  end

  sig { params(trickplay: T.nilable(Trickplay), base: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.trickplay_json(trickplay, base)
    return nil if trickplay.nil? || trickplay.version.zero?

    {
      sheet_url: "#{base}/trickplay/#{trickplay.version}/sheet-{index}.webp", interval: trickplay.interval_seconds,
      tile_width: trickplay.tile_width, tile_height: trickplay.tile_height, columns: trickplay.columns, rows: trickplay.rows,
      count: trickplay.thumbnail_count
    }
  end

  sig { params(track: Subtitles::Tracks::Track, base: String).returns(T::Hash[Symbol, T.untyped]) }
  def self.subtitle_json(track, base)
    {
      id: track.id, format: track.format, language: track.language, title: track.title, forced: track.forced,
      default: track.default, hearing_impaired: track.hearing_impaired, external: !track.sidecar_path.nil?,
      # Nothing draws it here: choosing it restarts the stream with it burned in.
      burn: track.format == Subtitles::Tracks::Format::Burn, stream_index: track.stream_index,
      urls: Subtitles::Extractor.extensions_for(track).to_h { |extension| [ extension, "#{base}/subtitles/#{track.id}.#{extension}" ] }
    }
  end

  sig { params(stream: MediaStream).returns(T::Hash[Symbol, T.untyped]) }
  def self.track_json(stream)
    {
      index: stream.index, codec: stream.codec, language: stream.language, title: stream.title,
      channels: stream.channels, sample_rate: stream.sample_rate, default: stream.default, forced: stream.forced
    }
  end
end
