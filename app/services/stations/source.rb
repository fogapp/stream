# typed: strict
# frozen_string_literal: true

module Stations
  # Everything a block's rules allow (PROPOSAL §7.7), as candidates with one
  # file each: the largest readable one, as Play would pick among equals. A
  # channel's schedule is the household's, so no profile's limits apply
  # here — the guide hides channels a profile may not see instead.
  module Source
    extend T::Sig

    # A file with no length can't be scheduled.
    MIN_SECONDS = 1.0

    sig { params(household_id: String, rules: T::Hash[String, T.untyped]).returns(T::Array[Candidate]) }
    def self.candidates(household_id, rules)
      rules = Rules.normalize(rules)
      kinds = Array(rules["kinds"])
      found = T.let([], T::Array[Candidate])
      found += movies(household_id, rules) if kinds.include?("movie")
      found += episodes(household_id, rules) if kinds.include?("episode")
      found += videos(household_id, rules) if kinds.include?("video")
      found
    end

    # A filler's longest: more than this is a program, not something between.
    FILLER_MAX = T.let(15 * 60, Integer)

    # What plays between programs (PROPOSAL §7.7), short enough to fit a gap.
    sig { params(station: Station).returns(T::Array[Candidate]) }
    def self.filler(station)
      filler = station.filler_enum
      scope =
        case filler
        when Station::Filler::Slate then nil
        when Station::Filler::Extras
          return extras(station.household_id, Extra.unscoped.where(household_id: station.household_id).select(:id))
        when Station::Filler::Videos
          Video.unscoped.where(household_id: station.household_id, channel_id: station.filler_channel_ids).select(:id)
        else T.absurd(filler)
        end
      return [] if scope.nil?

      rows = files("Video", scope, { "max_minutes" => FILLER_MAX / 60 })
        .joins("JOIN videos ON videos.id = editions.playable_id")
        .pluck(Arel.sql("DISTINCT ON (editions.playable_id) editions.playable_id, media_files.id, media_files.duration_seconds, videos.title"))
      rows.map do |id, file_id, duration, title|
        Candidate.new(playable_type: "Video", playable_id: id, media_file_id: file_id, duration: duration.to_f, series_key: "filler",
          series_title: title.to_s)
      end
    end

    sig { params(household_id: String, ids: T.untyped).returns(T::Array[Candidate]) }
    def self.extras(household_id, ids)
      Extra.unscoped.where(household_id: household_id, id: ids).joins(:media_file)
        .where(media_files: { state: MediaFile::State::Probed.serialize, missing_since: nil })
        .where("media_files.duration_seconds BETWEEN ? AND ?", 10, FILLER_MAX)
        .pluck("extras.id", "media_files.id", "media_files.duration_seconds", "extras.title").map do |id, file_id, duration, title|
          Candidate.new(playable_type: "Extra", playable_id: id, media_file_id: file_id, duration: duration.to_f, series_key: "filler",
            series_title: title.to_s)
        end
    end
    private_class_method :extras

    sig { params(household_id: String, rules: T::Hash[String, T.untyped]).returns(T::Array[Candidate]) }
    def self.movies(household_id, rules)
      scope = titles(Movie.unscoped.where(household_id: household_id), rules, "Movie")
      return [] if scope.nil?

      scope = scope.where("movies.studios && ARRAY[?]::varchar[]", rules["studios"]) if rules["studios"]
      # Networks choose shows; without studios a network channel airs no films.
      return [] if rules["networks"] && !rules["studios"]

      scope = scope.where(year: rules["year_from"]..) if rules["year_from"]
      scope = scope.where(year: ..rules["year_to"]) if rules["year_to"]
      rows = files("Movie", scope.select(:id), rules)
        .joins("JOIN movies ON movies.id = editions.playable_id")
        .pluck(Arel.sql("DISTINCT ON (editions.playable_id) editions.playable_id, media_files.id, media_files.duration_seconds, " \
          "movies.title, COALESCE(movies.release_date, make_date(movies.year, 1, 1))"))
      rows.map do |id, file_id, duration, title, released|
        Candidate.new(playable_type: "Movie", playable_id: id, media_file_id: file_id, duration: duration.to_f,
          series_key: "movies", series_title: title.to_s, aired_on: released)
      end
    end
    private_class_method :movies

    sig { params(household_id: String, rules: T::Hash[String, T.untyped]).returns(T::Array[Candidate]) }
    def self.episodes(household_id, rules)
      shows = titles(Show.unscoped.where(household_id: household_id), rules, "Show")
      return [] if shows.nil?
      return [] if rules["studios"] && !rules["networks"]

      shows = shows.where("shows.networks && ARRAY[?]::varchar[]", rules["networks"]) if rules["networks"]
      episodes = Episode.where(show_id: shows.select(:id))
      episodes = episodes.where("episodes.season_number > 0") unless rules["include_specials"]
      aired = "COALESCE(EXTRACT(YEAR FROM episodes.air_date)::int, (SELECT year FROM shows s WHERE s.id = episodes.show_id))"
      episodes = episodes.where("#{aired} >= ?", rules["year_from"]) if rules["year_from"]
      episodes = episodes.where("#{aired} <= ?", rules["year_to"]) if rules["year_to"]
      rows = files("Episode", episodes.select(:id), rules)
        .joins("JOIN episodes ON episodes.id = editions.playable_id JOIN shows ON shows.id = episodes.show_id")
        .pluck(Arel.sql("DISTINCT ON (editions.playable_id) editions.playable_id, media_files.id, media_files.duration_seconds, " \
          "shows.id, shows.title, episodes.season_number, COALESCE(episodes.episode_number, 0), episodes.air_date"))
      rows.map do |id, file_id, duration, show_id, title, season, number, aired_on|
        Candidate.new(playable_type: "Episode", playable_id: id, media_file_id: file_id, duration: duration.to_f,
          series_key: show_id, series_title: title.to_s, season: season.to_i, episode: number.to_i, aired_on: aired_on)
      end
    end
    private_class_method :episodes

    # YouTube videos (PROPOSAL §5.4), a channel's as a series in upload
    # order. Only the rules a video can answer; the others leave videos out.
    TITLE_ONLY = T.let(%w[genres keywords networks studios min_rating person_ids].freeze, T::Array[String])

    sig { params(household_id: String, rules: T::Hash[String, T.untyped]).returns(T::Array[Candidate]) }
    def self.videos(household_id, rules)
      return [] if TITLE_ONLY.any? { |key| rules[key] }
      return [] if rules["max_rating_age"] && !rules["allow_unrated"]

      scope = Video.unscoped.where(household_id: household_id)
      picked = picked_ids(rules, "Video")
      unless picked.nil?
        return [] if picked.empty?

        scope = scope.where(channel_id: picked)
      end
      scope = scope.where(library_id: rules["library_ids"]) if rules["library_ids"]
      scope = scope.where(upload_date: Date.new(rules["year_from"].to_i)..) if rules["year_from"]
      scope = scope.where(upload_date: ..Date.new(rules["year_to"].to_i, 12, 31)) if rules["year_to"]
      rows = files("Video", scope.select(:id), rules)
        .joins("JOIN videos ON videos.id = editions.playable_id JOIN channels ON channels.id = videos.channel_id")
        .pluck(Arel.sql("DISTINCT ON (editions.playable_id) editions.playable_id, media_files.id, media_files.duration_seconds, " \
          "channels.id, channels.title, videos.upload_date"))
      rows.map do |id, file_id, duration, channel_id, title, uploaded|
        Candidate.new(playable_type: "Video", playable_id: id, media_file_id: file_id, duration: duration.to_f,
          series_key: channel_id, series_title: title.to_s, aired_on: uploaded)
      end
    end
    private_class_method :videos

    # A readable file for each playable, largest first, the right length.
    sig { params(type: String, ids: T.untyped, rules: T::Hash[String, T.untyped]).returns(T.untyped) }
    def self.files(type, ids, rules)
      scope = Edition.joins(:media_file).where(playable_type: type, playable_id: ids)
        .where(media_files: { state: MediaFile::State::Probed.serialize, missing_since: nil })
        .where("media_files.duration_seconds >= ?", MIN_SECONDS)
      scope = scope.where("media_files.duration_seconds >= ?", rules["min_minutes"].to_i * 60) if rules["min_minutes"]
      scope = scope.where("media_files.duration_seconds <= ?", rules["max_minutes"].to_i * 60) if rules["max_minutes"]
      scope.reorder(Arel.sql("editions.playable_id, media_files.size DESC"))
    end
    private_class_method :files

    # Rules every title answers the same way, film or show. Nil: nothing
    # of this kind can match (only the other kind was picked).
    sig { params(scope: T.untyped, rules: T::Hash[String, T.untyped], type: String).returns(T.untyped) }
    def self.titles(scope, rules, type)
      table = scope.klass.table_name
      picked = picked_ids(rules, type)
      unless picked.nil?
        return nil if picked.empty?

        scope = scope.where(id: picked)
      end
      excluded = Array(rules[type == "Movie" ? "exclude_movie_ids" : "exclude_show_ids"])
      scope = scope.where.not(id: excluded) if excluded.any?
      scope = scope.where(library_id: rules["library_ids"]) if rules["library_ids"]
      scope = scope.where("#{table}.genres && ARRAY[?]::varchar[]", rules["genres"]) if rules["genres"]
      scope = scope.where.not("#{table}.genres && ARRAY[?]::varchar[]", rules["exclude_genres"]) if rules["exclude_genres"]
      scope = scope.where("#{table}.keywords && ARRAY[?]::varchar[]", rules["keywords"]) if rules["keywords"]
      scope = scope.where.not("#{table}.keywords && ARRAY[?]::varchar[]", rules["exclude_keywords"]) if rules["exclude_keywords"]
      scope = scope.where("#{table}.vote_average >= ?", rules["min_rating"]) if rules["min_rating"]
      if rules["max_rating_age"]
        allowed = scope.klass.arel_table[:rating_age].lteq(rules["max_rating_age"])
        allowed = allowed.or(scope.klass.arel_table[:rating_age].eq(nil)) if rules["allow_unrated"]
        scope = scope.where(allowed)
      end
      if rules["person_ids"]
        scope = scope.where(id: Credit.where(creditable_type: type, person_id: rules["person_ids"]).select(:creditable_id))
      end
      scope
    end
    private_class_method :titles

    # Titles picked by hand or through collections — for videos, their
    # channels — or nil when none were (then everything is in).
    sig { params(rules: T::Hash[String, T.untyped], type: String).returns(T.nilable(T::Array[String])) }
    def self.picked_ids(rules, type)
      shows = Array(rules["show_ids"])
      movies = Array(rules["movie_ids"])
      collections = Array(rules["collection_ids"])
      channels = Array(rules["channel_ids"])
      return nil if shows.empty? && movies.empty? && collections.empty? && channels.empty?
      return channels if type == "Video"

      ids = type == "Movie" ? movies.dup : shows.dup
      picked = Collection.unscoped.where(id: collections).includes(:collection_items).to_a
      if picked.any?
        # The household's schedule: a smart collection works itself out for
        # no one, not for whoever pressed Save.
        items = Current.set(profile: nil) { Collection.items_for(picked) }
        ids += items.values.flatten.select { |item| item.class.name == type }.map(&:id)
      end
      ids.uniq
    end
    private_class_method :picked_ids
  end
end
