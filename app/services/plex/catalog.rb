# typed: strict
# frozen_string_literal: true

module Plex
  # Which Stream movie or episode each Plex item is (PROPOSAL §7.4). By
  # external id first (TMDB, IMDb, TVDB — what both sides agree on), then
  # by the file itself (same name and size: the same bytes on the same
  # share), then by title and year. The answer doesn't depend on the Plex
  # user, so it's worked out once per run.
  class Catalog
    extend T::Sig

    class Match < T::Struct
      const :playable, T.any(Movie, Episode)
      const :how, String
    end

    sig { params(household_id: String).void }
    def initialize(household_id)
      @index = T.let(::Catalog::IdIndex.new(Movie.unscoped.where(household_id: household_id), Show.unscoped.where(household_id: household_id)),
        ::Catalog::IdIndex)
      @movies_by_title = T.let(@index.movies.index_by { |movie| title_key(movie.title, movie.year) }, T::Hash[String, Movie])
      @shows_by_title = T.let(@index.shows.index_by { |show| Media::NameParser.normalize(show.title) }, T::Hash[String, Show])
      @episodes = T.let(@index.episodes, T::Hash[T.untyped, Episode])
      @by_file = T.let(file_index(household_id), T::Hash[String, T.any(Movie, Episode)])
      @show_guids = T.let({}, T::Hash[String, T::Hash[String, String]])
    end

    # Plex shows by ratingKey, so episodes can use their show's ids.
    sig { params(show: T::Hash[String, T.untyped]).void }
    def remember_show(show)
      @show_guids[show["ratingKey"].to_s] = guids(show).merge("title" => show["title"].to_s)
    end

    sig { params(item: T::Hash[String, T.untyped]).returns(T.nilable(Match)) }
    def movie(item)
      ids = guids(item)
      found = (@index.movie_by_tmdb(ids["tmdb"]&.to_i)&.then { |movie| [ movie, "TMDB id" ] }) ||
        (@index.movie_by_imdb(ids["imdb"])&.then { |movie| [ movie, "IMDb id" ] }) ||
        (by_file(item)&.then { |playable| playable.is_a?(Movie) ? [ playable, "same file" ] : nil }) ||
        (@movies_by_title[title_key(item["title"].to_s, item["year"]&.to_i)]&.then { |movie| [ movie, "title and year" ] })
      found ? Match.new(playable: found[0], how: found[1]) : nil
    end

    # A Plex show (a SHOW listing item, or one remembered by ratingKey).
    sig { params(item: T::Hash[String, T.untyped]).returns(T.nilable(Show)) }
    def show(item)
      ids = guids(item)
      @index.show_by_tmdb(ids["tmdb"]&.to_i) || @index.show_by_tvdb(ids["tvdb"]&.to_i) ||
        @shows_by_title[Media::NameParser.normalize(item["title"].to_s)]
    end

    sig { params(item: T::Hash[String, T.untyped]).returns(T.nilable(Match)) }
    def episode(item)
      from_file = by_file(item)
      return Match.new(playable: from_file, how: "same file") if from_file.is_a?(Episode)

      show_ids = @show_guids.fetch(item["grandparentRatingKey"].to_s, {})
      show = @index.show_by_tmdb(show_ids["tmdb"]&.to_i) || @index.show_by_tvdb(show_ids["tvdb"]&.to_i) ||
        @shows_by_title[Media::NameParser.normalize(item["grandparentTitle"].to_s)]
      return nil if show.nil?

      episode = @episodes[[ show.id, item["parentIndex"].to_i, item["index"].to_i ]]
      episode ? Match.new(playable: episode, how: "season and episode number") : nil
    end

    private

    # Each file by its name and size: the same bytes on the same share. Only
    # a film's or an episode's: nothing else is in Plex's own terms.
    sig { params(household_id: String).returns(T::Hash[String, T.any(Movie, Episode)]) }
    def file_index(household_id)
      movies = @index.movies.index_by(&:id)
      episodes = @episodes.values.index_by(&:id)
      files = MediaFile.unscoped.where(household_id: household_id).where.not(state: MediaFile::State::Missing.serialize)
      Edition.where(media_file_id: files.select(:id), playable_type: %w[Movie Episode]).joins(:media_file)
        .pluck("media_files.path", "media_files.size", :playable_type, :playable_id)
        .each_with_object({}) do |(path, size, type, id), found|
          playable = type == "Movie" ? movies[id] : episodes[id]
          found[file_key(File.basename(path), size.to_i)] = playable if playable
        end
    end

    # "tmdb://348" → { "tmdb" => "348" }, from Plex's Guid list.
    sig { params(item: T::Hash[String, T.untyped]).returns(T::Hash[String, String]) }
    def guids(item)
      Array(item["Guid"]).each_with_object({}) do |guid, ids|
        scheme, value = guid["id"].to_s.split("://", 2)
        ids[scheme.to_s] = value.to_s if scheme.present? && value.present?
      end
    end

    sig { params(item: T::Hash[String, T.untyped]).returns(T.untyped) }
    def by_file(item)
      Array(item["Media"]).flat_map { |media| Array(media["Part"]) }.each do |part|
        found = @by_file[file_key(File.basename(part["file"].to_s), part["size"].to_i)]
        return found if found
      end
      nil
    end

    sig { params(name: String, size: Integer).returns(String) }
    def file_key(name, size) = "#{name}\0#{size}"

    sig { params(title: String, year: T.nilable(Integer)).returns(String) }
    def title_key(title, year) = "#{Media::NameParser.normalize(title)}\0#{year}"
  end
end
