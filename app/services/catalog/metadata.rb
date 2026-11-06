# typed: strict
# frozen_string_literal: true

module Catalog
  # Turns TMDB detail responses into our columns and credits (PROPOSAL §5.2),
  # respecting field locks. Frozen into our tables so a provider outage never
  # blocks browsing or playback.
  module Metadata
    extend T::Sig

    CAST_LIMIT = 20
    # Where content ratings come from when the metadata language names no
    # region. The household's own country is a later setting.
    DEFAULT_REGION = "US"

    sig { params(movie: Movie, details: T::Hash[String, T.untyped], region: String).void }
    def self.apply_movie(movie, details, region: DEFAULT_REGION)
      release = details["release_date"].presence
      movie.assign_unlocked(
        title: details["title"].presence || movie.title,
        original_title: details["original_title"],
        year: release&.slice(0, 4)&.to_i || movie.year,
        release_date: release,
        overview: details["overview"].presence,
        tagline: details["tagline"].presence,
        runtime_minutes: details["runtime"].to_i.nonzero?,
        genres: Array(details["genres"]).filter_map { |genre| genre["name"] },
        studios: names(details["production_companies"]),
        keywords: names(details.dig("keywords", "keywords")),
        vote_average: details["vote_average"],
        imdb_id: details["imdb_id"].presence,
        tmdb_collection_id: details.dig("belongs_to_collection", "id"),
        tmdb_collection_name: details.dig("belongs_to_collection", "name"),
        content_rating: movie_certification(details, region),
        poster_path: details["poster_path"],
        backdrop_path: details["backdrop_path"],
        logo_path: best_logo(details)
      )
      movie.tmdb_id = details.fetch("id").to_i
      movie.metadata_refreshed_at = Time.current
      Movie.transaction do
        movie.save!
        replace_credits(movie, details.fetch("credits", {}), creators: [])
      end
      Collections.attach(movie)
      Artworks.enqueue_for(movie)
      Trailers.remember(movie, Array(details.dig("videos", "results")))
    end

    sig { params(show: Show, details: T::Hash[String, T.untyped], region: String).void }
    def self.apply_show(show, details, region: DEFAULT_REGION)
      first_aired = details["first_air_date"].presence
      show.assign_unlocked(
        title: details["name"].presence || show.title,
        original_title: details["original_name"],
        year: first_aired&.slice(0, 4)&.to_i || show.year,
        first_air_date: first_aired,
        overview: details["overview"].presence,
        status: details["status"],
        network: Array(details["networks"]).first&.dig("name"),
        networks: names(details["networks"]),
        keywords: names(details.dig("keywords", "results")),
        genres: Array(details["genres"]).filter_map { |genre| genre["name"] },
        vote_average: details["vote_average"],
        imdb_id: details.dig("external_ids", "imdb_id").presence,
        tvdb_id: details.dig("external_ids", "tvdb_id"),
        content_rating: Array(details.dig("content_ratings", "results")).find { |r| r["iso_3166_1"] == region }&.dig("rating").presence,
        poster_path: details["poster_path"],
        backdrop_path: details["backdrop_path"],
        logo_path: best_logo(details)
      )
      show.tmdb_id = details.fetch("id").to_i
      show.metadata_refreshed_at = Time.current
      Show.transaction do
        show.save!
        replace_credits(show, details.fetch("credits", {}), creators: Array(details["created_by"]))
        Array(details["seasons"]).each do |season|
          row = show.seasons.find_or_initialize_by(season_number: season.fetch("season_number").to_i)
          row.update!(title: season["name"], overview: season["overview"].presence, air_date: season["air_date"],
            episode_count: season["episode_count"], poster_path: season["poster_path"], tmdb_id: season["id"])
        end
      end
      Artworks.enqueue_for(show)
      Trailers.remember(show, Array(details.dig("videos", "results")))
    end

    # Upserts every episode of one season from TMDB; episodes with files keep
    # their editions (rows are matched by number, never replaced).
    sig { params(show: Show, season_details: T::Hash[String, T.untyped]).returns(Season) }
    def self.apply_season(show, season_details)
      number = season_details.fetch("season_number").to_i
      season = show.seasons.find_or_initialize_by(season_number: number)
      season.update!(title: season_details["name"], overview: season_details["overview"].presence,
        air_date: season_details["air_date"], poster_path: season_details["poster_path"],
        tmdb_id: season_details["id"], episode_count: Array(season_details["episodes"]).size)
      Array(season_details["episodes"]).each do |details|
        episode = show.episodes.find_or_initialize_by(season_number: number,
          episode_number: details.fetch("episode_number").to_i)
        locked = episode.locked_fields.to_set
        attributes = {
          season: season, title: details["name"], overview: details["overview"].presence,
          air_date: details["air_date"], runtime_minutes: details["runtime"], still_path: details["still_path"],
          vote_average: details["vote_average"], tmdb_id: details["id"]
        }.reject { |key, _| locked.include?(key.to_s) }
        episode.update!(attributes)
      end
      jobs = [ SyncArtworkJob.new("Season", season.id) ] + season.episodes.map { |episode| SyncArtworkJob.new("Episode", episode.id) }
      ActiveJob.perform_all_later(jobs)
      season
    end

    # The names from a TMDB list of named things (networks, companies,
    # keywords), for what Grid channels choose by.
    sig { params(list: T.untyped).returns(T::Array[String]) }
    def self.names(list)
      Array(list).filter_map { |entry| entry.is_a?(Hash) ? entry["name"].to_s.strip.presence : nil }.uniq.first(50)
    end
    private_class_method :names

    sig { params(details: T::Hash[String, T.untyped], region: String).returns(T.nilable(String)) }
    def self.movie_certification(details, region)
      countries = Array(details.dig("release_dates", "results"))
      country = countries.find { |entry| entry["iso_3166_1"] == region }
      Array(country&.dig("release_dates")).map { |entry| entry["certification"] }.find(&:present?)
    end
    private_class_method :movie_certification

    # The highest-voted logo; the client already asked TMDB for the
    # metadata language first.
    sig { params(details: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def self.best_logo(details)
      logos = Array(details.dig("images", "logos"))
      logos.max_by { |logo| [ logo["iso_639_1"].nil? ? 0 : 1, logo["vote_average"].to_f ] }&.dig("file_path")
    end
    private_class_method :best_logo

    sig do
      params(creditable: T.any(Movie, Show), credits: T::Hash[String, T.untyped],
        creators: T::Array[T::Hash[String, T.untyped]]).void
    end
    def self.replace_credits(creditable, credits, creators:)
      rows = []
      Array(credits["cast"]).first(CAST_LIMIT).each_with_index do |member, index|
        rows << [ member, Credit::Role::Cast, member["character"].presence, nil, index ]
      end
      Array(credits["crew"]).each do |member|
        role =
          case member["job"]
          when "Director" then Credit::Role::Director
          when "Screenplay", "Writer", "Story" then Credit::Role::Writer
          end
        rows << [ member, role, nil, member["job"], rows.size ] if role
      end
      creators.each { |member| rows << [ member, Credit::Role::Creator, nil, "Creator", rows.size ] }

      creditable.credits.delete_all
      rows.uniq { |row| [ row[0]["id"], row[1] ] }.each do |member, role, character, job, order|
        person = upsert_person(member)
        next if person.nil?

        Credit.create!(person: person, creditable: creditable, role: role.serialize, character: character, job: job,
          order: order)
      end
    end
    private_class_method :replace_credits

    sig { params(member: T::Hash[String, T.untyped]).returns(T.nilable(Person)) }
    def self.upsert_person(member)
      tmdb_id = member["id"]
      return nil if tmdb_id.nil? || member["name"].blank?

      person = Person.find_or_initialize_by(tmdb_id: tmdb_id.to_i)
      person.update!(name: member["name"], profile_path: member["profile_path"].presence || person.profile_path)
      person
    rescue ActiveRecord::RecordNotUnique
      Person.find_by(tmdb_id: tmdb_id.to_i)
    end
    private_class_method :upsert_person
  end
end
