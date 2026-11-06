# typed: strict
# frozen_string_literal: true

module Trakt
  # Which Stream title each Trakt item is (PROPOSAL §7.4), by the ids both
  # sides agree on: a movie by TMDB or IMDb id, a show by TMDB, TVDB or IMDb
  # id, an episode by its show and its season and number. Only titles the
  # profile may see (Viewing::Access) are found, so nothing Trakt says
  # reaches a title outside it.
  class Catalog
    extend T::Sig

    Playable = T.type_alias { T.any(Movie, Episode) }

    sig { params(household_id: String).void }
    def initialize(household_id)
      @index = T.let(::Catalog::IdIndex.new(Viewing::Access.movies(Movie.unscoped.where(household_id: household_id)),
        Viewing::Access.shows(Show.unscoped.where(household_id: household_id))), ::Catalog::IdIndex)
      @episodes = T.let(@index.episodes, T::Hash[T.untyped, Episode])
    end

    sig { params(movie: T.untyped).returns(T.nilable(Movie)) }
    def movie(movie)
      ids = ids(movie)
      @index.movie_by_tmdb(ids["tmdb"].to_i) || @index.movie_by_imdb(ids["imdb"].to_s)
    end

    sig { params(show: T.untyped).returns(T.nilable(Show)) }
    def show(show)
      ids = ids(show)
      @index.show_by_tmdb(ids["tmdb"].to_i) || @index.show_by_tvdb(ids["tvdb"].to_i) || @index.show_by_imdb(ids["imdb"].to_s)
    end

    sig { params(show: T.nilable(Show), season: T.untyped, number: T.untyped).returns(T.nilable(Episode)) }
    def episode(show, season, number)
      show && @episodes[[ show.id, season.to_i, number.to_i ]]
    end

    # A history, playback, rating or watchlist row: { "movie" => ... } or
    # { "episode" => ..., "show" => ... } or { "show" => ... }.
    sig { params(row: T::Hash[String, T.untyped]).returns(T.nilable(T.any(Movie, Episode, Show))) }
    def item(row)
      if row["movie"] then movie(row["movie"])
      elsif row["episode"].is_a?(Hash)
        episode(show(row["show"]), row.dig("episode", "season"), row.dig("episode", "number"))
      elsif row["show"] then show(row["show"])
      end
    end

    # Every episode of a /sync/watched/shows row, with what Trakt says of it.
    sig do
      params(row: T::Hash[String, T.untyped],
        block: T.proc.params(episode: Episode, detail: T::Hash[String, T.untyped]).void).void
    end
    def each_watched_episode(row, &block)
      series = show(row["show"])
      return if series.nil?

      Array(row["seasons"]).each do |season|
        Array(season["episodes"]).each do |detail|
          found = episode(series, season["number"], detail["number"])
          block.call(found, detail) if found
        end
      end
    end

    sig { params(item: T.any(Movie, Episode, Show)).returns(String) }
    def self.key(item) = "#{item.class.name}:#{item.id}"

    private

    sig { params(item: T.untyped).returns(T::Hash[String, T.untyped]) }
    def ids(item)
      found = item.is_a?(Hash) ? item["ids"] : nil
      found.is_a?(Hash) ? found : {}
    end
  end
end
