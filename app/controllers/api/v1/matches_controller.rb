# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Needs match and Fix match (PROPOSAL §5.2, hook's needs_review): titles
    # the matcher wouldn't guess at, their candidates with reasons, a search,
    # and a pick. Everyone sees the queue; an admin resolves it.
    class MatchesController < BaseController
      before_action :require_admin!, except: %i[index folders]
      # The queue is for the grown-ups who fix it, as the sidebar says.
      before_action :require_grown_up!, only: %i[index folders]
      # TMDB not answering a search, a pick or a split.
      answers_upstream_errors prefix: "TMDB: "

      MAX_LISTED = 200

      sig { void }
      def index
        movies = Movie.needing_match.includes(:library).order(:sort_title).limit(MAX_LISTED)
        shows = Show.needing_match.includes(:library).order(:sort_title).limit(MAX_LISTED)
        render json: movies.map { |movie| MatchSerializer.title_json(movie) } + shows.map { |show| MatchSerializer.title_json(show) }
      end

      sig { void }
      def folders
        filed_twice = ShowFolder.group(:show_id).having("count(*) > 1").select(:show_id)
        shows = Show.where(id: filed_twice).includes(:library, :folders).order(:sort_title).limit(MAX_LISTED)
        render json: shows.map { |show| MatchSerializer.folders_json(show) }
      end

      # "Not this show" on one of a show's folders (Show info): that folder
      # goes back to Needs match, under a show of its own if it shared one.
      sig { void }
      def reject
        show = Show.find(params.require(:id))
        folder = params.require(:folder).to_s
        return render_errors("#{show.title} isn't filed from #{folder}", status: :not_found) unless show.folders.exists?(folder: folder)

        client = Tmdb::Client.for(current_household!, language: show.library&.metadata_language || "en")
        split = Catalog::ShowSplit.call(show, folder, by: current_user!.name, client: client)
        render json: MatchSerializer.title_json(split)
      end

      sig { void }
      def search
        client = tmdb_client
        return if client.nil?

        year = params[:year].presence&.to_i
        candidates = Catalog::TitleMatcher.new(client).search(library_kind, params.require(:query).to_s, year: year)
        render json: candidates.map(&:to_h)
      end

      sig { void }
      def create
        client = tmdb_client
        return if client.nil?

        tmdb_id = Integer(params.require(:tmdb_id).to_s, exception: false)
        return render_errors("tmdb_id must be a number", status: :bad_request) if tmdb_id.nil?

        matcher = Catalog::TitleMatcher.new(client)
        chosen =
          case (record = title)
          when Movie then matcher.choose_movie(record, tmdb_id, reason: "chosen by #{current_user!.name}")
          when Show
            matcher.choose_show(record, tmdb_id, reason: "chosen by #{current_user!.name}").tap { |show| refile(show) }
          end
        render json: MatchSerializer.title_json(chosen)
      end

      private

      sig { returns(T.any(Movie, Show)) }
      def title
        @title ||= T.let(
          case params.require(:kind).to_s
          when "movie" then Movie.find(params.require(:id))
          when "show" then Show.find(params.require(:id))
          else raise ActiveRecord::RecordNotFound
          end,
          T.nilable(T.any(Movie, Show))
        )
      end

      sig { returns(Library::Kind) }
      def library_kind = title.is_a?(Movie) ? Library::Kind::Movies : Library::Kind::Shows

      sig { returns(T.nilable(Tmdb::Client)) }
      def tmdb_client
        client = Tmdb::Client.for(current_household!, language: title.library&.metadata_language || "en")
        render_errors("Add a TMDB key in Settings › Integrations first") if client.nil?
        client
      end

      # A newly identified show has TMDB seasons to fill and episodes to
      # renumber against them: refile its files.
      sig { params(show: Show).void }
      def refile(show)
        file_ids = Edition.where(playable_type: "Episode", playable_id: show.episodes.select(:id)).distinct.pluck(:media_file_id)
        ActiveJob.perform_all_later(MatchMediaFileJob.for_files(file_ids))
      end
    end
  end
end
