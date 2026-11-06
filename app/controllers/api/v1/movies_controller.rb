# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Movie grids and pages (PROPOSAL §7.2).
    class MoviesController < BaseController
      finds :movie, from: -> { Viewing::Access.movies(Movie.all) }
      skip_before_action :set_movie, only: %i[index letters]

      # More like this (PROPOSAL §7.1).
      sig { void }
      def similar
        titles = Recommendations::Similar.to(movie)
        cards = Viewing::Cards.new(current_profile!).prime(titles)
        render json: titles.map { |title| cards.card(title) }
      end

      sig { void }
      def index
        movies = paginate(Viewing::Catalog.browse(grid, sort: params[:sort], query: params[:q]), default_per: 120).to_a
        cards = Viewing::Cards.new(current_profile!).prime(movies)
        render json: movies.map { |movie| cards.card(movie) }
      end

      # Where each letter starts in the A–Z grid, for its alphabet.
      sig { void }
      def letters
        titles = Viewing::Catalog.browse(grid, sort: "title", query: params[:q]).pluck(:sort_title)
        render json: CatalogSerializer.letters_json(Viewing::Catalog.letters(titles))
      end

      sig { void }
      def show
        credits = movie.credits.includes(:person).to_a
        people = credits.filter_map(&:person)
        extras = Viewing::Catalog.playable_extras(movie.extras)
        images = ArtworkSerializer.index([ movie ] + people + extras)
        edition_names = movie.editions.to_h { |edition| [ edition.media_file_id, edition.name ] }
        files = movie.playable_files.includes(:media_streams).order(size: :desc)
        state = WatchState.find_by(profile: current_profile!, playable: movie)
        render json: CatalogSerializer.movie_card(movie, images, state ? { movie.id => state } : {}).merge(
          trailer: Trailers.json(movie),
          original_title: movie.original_title, tagline: movie.tagline, overview: movie.overview,
          genres: movie.genres, release_date: movie.release_date, vote_average: movie.vote_average,
          collection: movie.tmdb_collection_name, library: { id: movie.library_id, name: movie.library&.name },
          match_state: movie.match_state_enum, tmdb_id: movie.tmdb_id, imdb_id: movie.imdb_id,
          resume_at: state&.resume_seconds,
          play_count: state&.play_count || 0,
          versions: files.map { |file| CatalogSerializer.version_json(file, edition: edition_names[file.id]) },
          extras: CatalogSerializer.extras_json(extras, images),
          collections: CatalogSerializer.collections_json(movie),
          locked_fields: movie.locked_fields, content_rating: movie.content_rating,
          my_rating: Rating.find_by(profile: current_profile!, rateable: movie)&.value,
          cast: CatalogSerializer.cast_json(credits, images)
        )
      end

      private

      # The movies a grid shows, before sorting and search.
      sig { returns(T.untyped) }
      def grid
        scope = Viewing::Catalog.watchable_movies
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        scope = Viewing::Catalog.with_external_ids(scope, external_id_filters(%i[tmdb_id imdb_id]))
        return scope unless bool_param(:unwatched)

        watched = WatchState.finished(current_profile!, "Movie")
        scope.where.not(id: watched.select(:playable_id))
      end
    end
  end
end
