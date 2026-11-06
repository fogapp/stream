# typed: strict
# frozen_string_literal: true

module Catalog
  # A household's titles by the ids other services know them by, for
  # bringing a whole account across (Trakt::Catalog, Plex::Catalog). Only the
  # columns that's done with: a full row carries an embedding and the match
  # candidates, and this is every title, every sync.
  class IdIndex
    extend T::Sig

    TITLE_COLUMNS = T.let(%i[id household_id library_id title year tmdb_id imdb_id].freeze, T::Array[Symbol])
    SHOW_COLUMNS = T.let([ *TITLE_COLUMNS, :tvdb_id ].freeze, T::Array[Symbol])
    EPISODE_COLUMNS = T.let(%i[id show_id season_number episode_number].freeze, T::Array[Symbol])

    sig { returns(T::Array[Movie]) }
    attr_reader :movies

    sig { returns(T::Array[Show]) }
    attr_reader :shows

    # The scopes decide which titles: Trakt's goes through Viewing::Access.
    sig { params(movies: T.untyped, shows: T.untyped).void }
    def initialize(movies, shows)
      @movies = T.let(movies.select(TITLE_COLUMNS).to_a, T::Array[Movie])
      @shows = T.let(shows.select(SHOW_COLUMNS).to_a, T::Array[Show])
      @movies_by_tmdb = T.let(@movies.select(&:tmdb_id).index_by(&:tmdb_id), T::Hash[T.untyped, Movie])
      @movies_by_imdb = T.let(@movies.select(&:imdb_id).index_by(&:imdb_id), T::Hash[T.untyped, Movie])
      @shows_by_tmdb = T.let(@shows.select(&:tmdb_id).index_by(&:tmdb_id), T::Hash[T.untyped, Show])
      @shows_by_tvdb = T.let(@shows.select(&:tvdb_id).index_by(&:tvdb_id), T::Hash[T.untyped, Show])
      @shows_by_imdb = T.let(@shows.select(&:imdb_id).index_by(&:imdb_id), T::Hash[T.untyped, Show])
    end

    # Every numbered episode of these shows, with its show already to hand,
    # as [show id, season, number] => episode.
    sig { returns(T::Hash[T.untyped, Episode]) }
    def episodes
      shows = @shows.index_by(&:id)
      Episode.where(show_id: shows.keys).where.not(episode_number: nil).select(EPISODE_COLUMNS).each_with_object({}) do |episode, found|
        episode.association(:show).target = shows[episode.show_id]
        found[[ episode.show_id, episode.season_number, episode.episode_number ]] = episode
      end
    end

    sig { params(id: T.untyped).returns(T.nilable(Movie)) }
    def movie_by_tmdb(id) = @movies_by_tmdb[id]

    sig { params(id: T.untyped).returns(T.nilable(Movie)) }
    def movie_by_imdb(id) = @movies_by_imdb[id]

    sig { params(id: T.untyped).returns(T.nilable(Show)) }
    def show_by_tmdb(id) = @shows_by_tmdb[id]

    sig { params(id: T.untyped).returns(T.nilable(Show)) }
    def show_by_tvdb(id) = @shows_by_tvdb[id]

    sig { params(id: T.untyped).returns(T.nilable(Show)) }
    def show_by_imdb(id) = @shows_by_imdb[id]
  end
end
