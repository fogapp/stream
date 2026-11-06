# typed: strict
# frozen_string_literal: true

module MediaFileSerializer
  extend T::Sig

  # Ids of the titles behind these editions the watching profile may see;
  # nil when it may see them all.
  Visible = T.type_alias { T.nilable(T::Set[String]) }

  # A page of files, with what each is an edition of, in a fixed number of
  # queries (editions and their playables are preloaded by the caller).
  sig { params(files: T::Array[MediaFile]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.list_json(files)
    visible = preload_titles(files)
    files.map { |file| summary_json(file, visible) }
  end

  sig { params(file: MediaFile, visible: Visible).returns(T::Hash[Symbol, T.untyped]) }
  def self.summary_json(file, visible)
    {
      id: file.id, library: { id: file.library_id, name: file.library&.name },
      path: file.path, filename: file.filename, size: file.size, mtime: file.mtime,
      state: file.state_enum, container: file.container, duration_seconds: file.duration_seconds,
      bit_rate: file.bit_rate, last_error: file.last_error, missing_since: file.missing_since,
      probed_at: file.probed_at, fingerprint: file.fingerprint,
      matches: file.editions.filter_map { |edition| match_json(edition, visible) }
    }
  end

  # What a file is an edition of, by the ids Hook knows it by: a movie, or
  # an episode (a file may hold several).
  sig { params(edition: Edition, visible: Visible).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.match_json(edition, visible)
    playable = edition.playable
    return nil if visible && !visible.include?(playable&.id)

    case playable
    when Movie
      { type: "movie", id: playable.id, tmdb_id: playable.tmdb_id, imdb_id: playable.imdb_id, edition: edition.name }
    when Episode
      { type: "episode", id: playable.id, show_id: playable.show_id, show_tmdb_id: playable.show&.tmdb_id,
        season_number: playable.season_number, episode_number: playable.episode_number }
    end
  end

  # Loads each episode's show in one query and works out which titles the
  # watching profile may see (Viewing::Access), so a restricted profile's
  # list names no title it couldn't open.
  sig { params(files: T::Array[MediaFile]).returns(Visible) }
  def self.preload_titles(files)
    playables = files.flat_map { |file| file.editions.map(&:playable) }.compact
    episodes = playables.grep(Episode)
    ActiveRecord::Associations::Preloader.new(records: episodes, associations: :show).call if episodes.any?
    return nil if Viewing::Access.profile.nil?

    movie_ids = playables.grep(Movie).map(&:id)
    movies = movie_ids.any? ? Viewing::Access.movies(Movie.where(id: movie_ids)).pluck(:id) : []
    shown = episodes.any? ? Viewing::Access.episodes(Episode.where(id: episodes.map(&:id))).pluck(:id) : []
    (movies + shown).to_set
  end
  private_class_method :preload_titles

  # The raw ffprobe JSON stays server-side: it can run to megabytes for a
  # file with chapters and attachments, and nothing on the page reads it.
  sig { params(file: MediaFile).returns(T::Hash[Symbol, T.untyped]) }
  def self.detail_json(file)
    summary_json(file, preload_titles([ file ])).merge(
      keyframes: { count: file.keyframes&.size, source: file.keyframes_source },
      chapters: file.chapters,
      markers: MarkerSerializer.list(file, detail: true),
      titles: file.editions.filter_map { |edition| title_link(edition) },
      subtitles: Subtitles::Tracks.for(file).map do |track|
        { id: track.id, format: track.format, language: track.language, title: track.title, forced: track.forced,
          external: !track.sidecar_path.nil?, codec: track.codec }
      end,
      devices: Playback::Report.device_decisions(file),
      optimized: file.optimized_version&.then { |version| OptimizedVersionSerializer.json(version) },
      streams: file.media_streams.map { |stream| stream_json(stream) },
      analysis: AnalysisRun::Step.values.map do |step|
        run = file.analysis_runs.find { |candidate| candidate.step_enum == step }
        analysis_json(step, run)
      end
    )
  end

  sig { params(edition: Edition).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.title_link(edition)
    playable = edition.playable
    case playable
    when Movie then { kind: "movie", id: playable.id, title: Playback::Report.title_for(playable), path: "/movie/#{playable.id}" }
    when Episode then { kind: "episode", id: playable.id, title: Playback::Report.title_for(playable), path: "/show/#{playable.show_id}?season=#{playable.season_number}" }
    end
  end

  sig { params(stream: MediaStream).returns(T::Hash[Symbol, T.untyped]) }
  def self.stream_json(stream)
    {
      index: stream.index, kind: stream.kind_enum, codec: stream.codec, profile: stream.profile,
      level: stream.level, bit_depth: stream.bit_depth, width: stream.width, height: stream.height,
      frame_rate: stream.frame_rate, pixel_format: stream.pixel_format, hdr_format: stream.hdr_format_enum,
      dolby_vision_profile: stream.dolby_vision_profile, channels: stream.channels,
      channel_layout: stream.channel_layout, language: stream.language, title: stream.title,
      bit_rate: stream.bit_rate, default: stream.default, forced: stream.forced
    }
  end

  # Every step appears, run or not, so the page is a checklist.
  sig { params(step: AnalysisRun::Step, run: T.nilable(AnalysisRun)).returns(T::Hash[Symbol, T.untyped]) }
  def self.analysis_json(step, run)
    {
      step: step, status: run&.status_enum || AnalysisRun::Status::Pending,
      started_at: run&.started_at, finished_at: run&.finished_at, duration_ms: run&.duration_ms,
      tool_version: run&.tool_version, error: run&.error, consecutive_failures: run&.consecutive_failures || 0
    }
  end
end
