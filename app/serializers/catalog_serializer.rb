# typed: strict
# frozen_string_literal: true

# Cards and pages for the viewing surface (PROPOSAL §7.1–7.2). Every list
# endpoint batch-loads its artwork and watch states and hands them in, so a
# grid of two hundred posters is a handful of queries.
module CatalogSerializer
  extend T::Sig

  WatchIndex = T.type_alias { T::Hash[String, WatchState] }

  sig { params(movie: Movie, images: ArtworkSerializer::Index, watch: WatchIndex).returns(T::Hash[Symbol, T.untyped]) }
  def self.movie_card(movie, images, watch)
    state = watch[movie.id]
    {
      kind: "movie", id: movie.id, title: movie.title, year: movie.year, content_rating: movie.content_rating,
      runtime_minutes: movie.runtime_minutes, images: ArtworkSerializer.images(images, movie),
      tmdb_id: movie.tmdb_id, imdb_id: movie.imdb_id,
      **watch_json(state)
    }
  end

  # How far a card's bar goes: nothing until it's started, and no bar once
  # it's finished.
  sig { params(state: T.nilable(WatchState)).returns(T.nilable(Float)) }
  def self.progress(state) = state && !state.completed? ? state.progress.round(3).to_f : nil

  sig { params(state: T.nilable(WatchState)).returns({ progress: T.nilable(Float), watched: T::Boolean }) }
  def self.watch_json(state) = { progress: progress(state), watched: state&.completed? || false }

  # Where each letter starts in an A–Z grid: "#" first, then A–Z, only
  # the letters some title files under.
  sig { params(starts: T::Array[[ String, Integer ]]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.letters_json(starts)
    starts.map { |letter, index| { letter: letter, index: index } }
  end

  sig do
    params(show: Show, images: ArtworkSerializer::Index, unwatched: T::Hash[String, Integer])
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.show_card(show, images, unwatched)
    {
      kind: "show", id: show.id, title: show.title, year: show.year, content_rating: show.content_rating,
      images: ArtworkSerializer.images(images, show), unwatched_count: unwatched.fetch(show.id, 0),
      tmdb_id: show.tmdb_id, tvdb_id: show.tvdb_id, imdb_id: show.imdb_id
    }
  end

  sig do
    params(episode: Episode, images: ArtworkSerializer::Index, state: T.nilable(WatchState))
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.episode_card(episode, images, state)
    show = episode.show
    {
      kind: "episode", id: episode.id, code: episode.code, title: episode.title,
      season_number: episode.season_number, episode_number: episode.episode_number,
      show: show && { id: show.id, title: show.title, images: ArtworkSerializer.images(images, show) },
      images: ArtworkSerializer.images(images, episode),
      **watch_json(state)
    }
  end

  sig do
    params(video: Video, images: ArtworkSerializer::Index, state: T.nilable(WatchState), duration: T.nilable(Float))
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.video_card(video, images, state, duration: nil)
    channel = video.channel
    {
      kind: "video", id: video.id, title: video.title, upload_date: video.upload_date, duration_seconds: duration,
      channel: channel && { id: channel.id, title: channel.title, avatar: ArtworkSerializer.images(images, channel)["profile"] },
      images: ArtworkSerializer.images(images, video),
      **watch_json(state)
    }
  end

  sig do
    params(channel: Channel, images: ArtworkSerializer::Index, counts: T::Hash[Symbol, T.untyped])
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.channel_card(channel, images, counts)
    own = ArtworkSerializer.images(images, channel)
    {
      kind: "channel", id: channel.id, title: channel.title, handle: channel.handle,
      avatar: own["profile"], banner: own["backdrop"], video_count: counts.fetch(:videos, 0),
      unwatched_count: counts.fetch(:unwatched, 0), latest_upload: counts[:latest]
    }
  end

  # The collections a title is in, for its page.
  sig { params(item: T.any(Movie, Show)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.collections_json(item)
    Collection.joins(:collection_items).where(collection_items: { item_type: item.class.name, item_id: item.id })
      .order(:sort_title).map { |collection| { id: collection.id, title: collection.title, kind: collection.kind_enum } }
  end

  sig { params(extras: T::Array[Extra], images: ArtworkSerializer::Index).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.extras_json(extras, images)
    extras.sort_by { |extra| [ Extra::ORDER.index(extra.kind).to_i, extra.title ] }.map do |extra|
      owner = extra.owner
      { kind: "extra", id: extra.id, extra_kind: extra.kind_enum, kind_label: extra.kind_label, title: extra.title,
        duration_seconds: extra.media_file&.duration_seconds, images: ArtworkSerializer.images(images, extra),
        season_number: owner.is_a?(Season) ? owner.season_number : nil }
    end
  end

  # Every episode of a show, with or without a file (Hook's inventory,
  # GET /shows/:id/episodes). Files only for an admin, as on a season.
  sig do
    params(episodes: T::Array[Episode], files: T::Boolean).returns(T::Array[T::Hash[Symbol, T.untyped]])
  end
  def self.episode_inventory_json(episodes, files:)
    episodes.map do |episode|
      readable = episode.editions.any? { |edition| edition.media_file&.state_enum == MediaFile::State::Probed }
      {
        id: episode.id, season_number: episode.season_number, episode_number: episode.episode_number,
        title: episode.title, air_date: episode.air_date, available: readable
      }.merge(files ? { files: episode_files_json(episode) } : {})
    end
  end

  # Every file behind an episode, whatever its state, for an admin.
  sig { params(episode: Episode).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.episode_files_json(episode)
    episode.editions.filter_map do |edition|
      file = edition.media_file
      file && { id: file.id, path: file.path, state: file.state_enum, size: file.size, video: video_label(file),
                edition: edition.name }
    end
  end

  # Where each profile is in a show (Hook's GET /shows/:id/progress).
  sig { params(rows: T::Array[Viewing::ShowProgress::Row]).returns(T::Hash[Symbol, T.untyped]) }
  def self.show_progress_json(rows)
    {
      profiles: rows.map do |row|
        nxt = row.next_up
        { id: row.profile.id, name: row.profile.name, last_watched_at: row.last_watched_at, watched_count: row.watched_count,
          next_up: nxt && { episode_id: nxt.id, season_number: nxt.season_number, episode_number: nxt.episode_number } }
      end
    }
  end

  # "1080p HEVC HDR10": a file's video at a glance, nil until probed.
  sig { params(file: MediaFile).returns(T.nilable(String)) }
  def self.video_label(file)
    video = file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Video }
    video && [ resolution(video.height), video.codec&.upcase, video.hdr_format_enum&.serialize&.upcase ].compact.join(" ")
  end

  sig { params(file: MediaFile, edition: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
  def self.version_json(file, edition: nil)
    video = file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Video }
    audio = file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Audio }
    {
      media_file_id: file.id, edition: edition, filename: file.filename, size: file.size, duration_seconds: file.duration_seconds,
      video: video_label(file),
      audio: audio && [ audio.codec&.upcase, channels(audio.channels) ].compact.join(" "),
      subtitles: file.media_streams.count { |stream| stream.kind_enum == MediaStream::Kind::Subtitle },
      playable: !video.nil?, unplayable_reason: video.nil? ? "There's no video in this file" : nil
    }
  end

  sig { params(credits: T::Array[Credit], images: ArtworkSerializer::Index).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.cast_json(credits, images)
    credits.filter_map do |credit|
      person = credit.person
      next if person.nil?

      { person_id: person.id, name: person.name, role: credit.role_enum, character: credit.character, job: credit.job,
        image: ArtworkSerializer.images(images, person)["profile"] }
    end
  end

  sig { params(height: T.nilable(Integer)).returns(T.nilable(String)) }
  def self.resolution(height)
    return nil if height.nil?
    return "4K" if height >= 2000
    return "1080p" if height >= 1000
    return "720p" if height >= 700

    "#{height}p"
  end

  sig { params(count: T.nilable(Integer)).returns(T.nilable(String)) }
  def self.channels(count)
    case count
    when nil then nil
    when 1 then "Mono"
    when 2 then "Stereo"
    when 6 then "5.1"
    when 8 then "7.1"
    else "#{count}ch"
    end
  end

  # A collection without its own poster wears its first title's.
  sig do
    params(collection: Collection, items: T::Array[T.any(Movie, Show)], images: ArtworkSerializer::Index)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.collection_card(collection, items, images)
    own = ArtworkSerializer.images(images, collection)
    first = items.first
    borrowed = first ? ArtworkSerializer.images(images, first) : {}
    {
      kind: "collection", id: collection.id, title: collection.title, collection_kind: collection.kind_enum,
      library: collection.library && { id: collection.library_id, name: collection.library&.name }, item_count: items.size, images: { "poster" => own["poster"] || borrowed["poster"],
                                        "backdrop" => own["backdrop"] || borrowed["backdrop"] }.compact
    }
  end
end
