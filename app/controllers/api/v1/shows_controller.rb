# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Show grids, show pages, season episode lists (PROPOSAL §7.2).
    class ShowsController < BaseController
      # Not `finds :show`: its reader would shadow the show action.
      finds :series, from: -> { Viewing::Access.shows(Show.all) }
      skip_before_action :set_series, only: %i[index letters]
      # Every profile's progress is the household's, not this profile's.
      before_action :require_admin!, only: %i[info progress]

      sig { void }
      def index
        scope = Viewing::Catalog.watchable_shows
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        scope = Viewing::Catalog.with_external_ids(scope, external_id_filters(%i[tmdb_id tvdb_id imdb_id]))
        scope = Viewing::Catalog.with_unwatched(scope, current_profile!) if bool_param(:unwatched)
        shows = paginate(Viewing::Catalog.browse(scope, sort: params[:sort], query: params[:q]), default_per: 120).to_a
        cards = Viewing::Cards.new(current_profile!).prime(shows)
        render json: shows.map { |show| cards.card(show) }
      end

      # Where each letter starts in the A–Z grid, for its alphabet.
      sig { void }
      def letters
        scope = Viewing::Catalog.watchable_shows
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        scope = Viewing::Catalog.with_unwatched(scope, current_profile!) if bool_param(:unwatched)
        sort_titles = Viewing::Catalog.browse(scope, sort: "title", query: params[:q]).pluck(:sort_title)
        render json: CatalogSerializer.letters_json(Viewing::Catalog.letters(sort_titles))
      end

      # More like this (PROPOSAL §7.1).
      sig { void }
      def similar
        titles = Recommendations::Similar.to(series)
        cards = Viewing::Cards.new(current_profile!).prime(titles)
        render json: titles.map { |title| cards.card(title) }
      end

      sig { void }
      def show
        credits = series.credits.includes(:person).to_a
        seasons = series.seasons.to_a
        extras = Viewing::Catalog.playable_extras(Extra.where(owner: series).or(Extra.where(owner_type: "Season", owner_id: seasons.map(&:id))).preload(:owner))
        images = ArtworkSerializer.index([ series ] + seasons + credits.filter_map(&:person) + extras)
        render json: CatalogSerializer.show_card(series, images, Viewing::Catalog.unwatched_counts(current_profile!, [ series ])).merge(
          overview: series.overview, genres: series.genres, status: series.status, network: series.network,
          first_air_date: series.first_air_date, vote_average: series.vote_average,
          library: { id: series.library_id, name: series.library&.name }, match_state: series.match_state_enum,
          tmdb_id: series.tmdb_id, seasons: season_summaries(seasons, images), next_up: next_up_json, trailer: Trailers.json(series),
          cast: CatalogSerializer.cast_json(credits, images),
          extras: CatalogSerializer.extras_json(extras, images),
          collections: CatalogSerializer.collections_json(series),
          locked_fields: series.locked_fields, original_title: series.original_title,
          my_rating: Rating.find_by(profile: current_profile!, rateable: series)&.value
        )
      end

      # The raw record behind the page, for an admin (Info).
      sig { void }
      def info
        render json: ShowInfoSerializer.json(series)
      end

      sig { void }
      def season
        number = params.require(:season_number).to_i
        season = series.seasons.find_by!(season_number: number)
        episodes = season.episodes.includes(:show, editions: { media_file: :media_streams }).to_a
        available = Viewing::Catalog.readable_editions.where(playable: episodes).distinct.pluck(:playable_id).to_set
        ratings = Rating.where(profile: current_profile!, rateable: episodes).pluck(:rateable_id, :value).to_h
        images = ArtworkSerializer.index(episodes + [ series ])
        watch = Viewing::Catalog.watch_index(current_profile!, episodes)
        admin = sees_files?
        render json: {
          season_number: season.season_number, title: season.display_title, overview: season.overview,
          episodes: episodes.map do |episode|
            CatalogSerializer.episode_card(episode, images, watch[episode.id]).merge(
              overview: episode.overview, air_date: episode.air_date, runtime_minutes: episode.runtime_minutes,
              available: available.include?(episode.id), locked_fields: episode.locked_fields,
              resume_at: watch[episode.id]&.resume_seconds,
              my_rating: ratings[episode.id],
              # More than one file (a remaster, an extended cut): which to play.
              versions: episode_versions(episode)
            ).merge(admin ? { files: CatalogSerializer.episode_files_json(episode) } : {})
          end
        }
      end

      # Every episode Stream knows for the show, every season and specials,
      # with or without a file (Hook's inventory).
      sig { void }
      def episodes
        list = series.episodes.includes(editions: { media_file: :media_streams })
          .reorder(:season_number, :episode_number, :air_date).to_a
        render json: CatalogSerializer.episode_inventory_json(list, files: sees_files?)
      end

      # Where each profile of the household is in the show (Hook's keep-ahead).
      sig { void }
      def progress
        render json: CatalogSerializer.show_progress_json(Viewing::ShowProgress.for(series))
      end

      sig { params(episode: Episode).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def episode_versions(episode)
        editions = episode.editions.select { |edition| edition.media_file&.state_enum == MediaFile::State::Probed }
        return [] if editions.size < 2

        editions.map { |edition| CatalogSerializer.version_json(T.must(edition.media_file), edition: edition.name) }
      end

      # What this profile always skips in this show (PROPOSAL §7.3).
      sig { void }
      def preferences
        preference = ShowPreference.find_or_initialize_by(profile: current_profile!, show: series)
        %i[skip_intro skip_recap skip_credits].each do |key|
          preference.public_send(:"#{key}=", bool_param(key)) if params.key?(key)
        end
        preference.save!
        render json: { skip_intro: preference.skip_intro, skip_recap: preference.skip_recap, skip_credits: preference.skip_credits }
      end

      # Marks a whole show, or one season of it, watched or unwatched.
      sig { void }
      def watched
        episodes = Viewing::NextUp.available(series)
        episodes = episodes.where(season_number: params[:season_number].to_i) if params[:season_number].present?
        flag = bool_param(:watched, default: true)
        episodes.each { |episode| Playback::Progress.mark(current_profile!, episode, watched: flag) }
        head :no_content
      end

      private

      # Paths are an admin's, and never from a kid profile.
      sig { returns(T::Boolean) }
      def sees_files? = current_user!.admin? && !current_profile!.kid?

      sig { params(seasons: T::Array[Season], images: ArtworkSerializer::Index).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def season_summaries(seasons, images)
        available = Viewing::NextUp.available(series).unscope(:order).group(:season_number).count
        watched_ids = WatchState.finished(current_profile!, "Episode").select(:playable_id)
        watched = Viewing::NextUp.available(series).unscope(:order).where(id: watched_ids).group(:season_number).count
        seasons.filter_map do |season|
          count = available.fetch(season.season_number, 0)
          next if count.zero? && season.season_number.zero?

          {
            season_number: season.season_number, title: season.display_title, episode_count: season.episode_count,
            available_count: count, watched_count: watched.fetch(season.season_number, 0),
            images: ArtworkSerializer.images(images, season)
          }
        end
      end

      sig { returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def next_up_json
        pick = Viewing::NextUp.for(series, current_profile!)
        return nil if pick.nil?

        resume = pick.state&.resume_seconds
        {
          episode_id: pick.episode.id, code: pick.episode.code, title: pick.episode.title,
          resume_at: resume&.positive? ? resume : nil,
          started_show: pick.started_show
        }
      end
    end
  end
end
