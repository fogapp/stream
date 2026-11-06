# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Libraries (PROPOSAL §4.1, §5.1). Everyone can see the
    # libraries; only an admin changes them or starts a scan.
    class LibrariesController < BaseController
      finds :library, from: -> { Library.all }
      skip_before_action :set_library, only: %i[index create validate_path fog_suggestions]
      before_action :require_admin!, except: %i[index show]

      sig { void }
      def index
        libraries = Library.order(:name).to_a
        render json: LibrarySerializer.list_json(libraries)
      end

      sig { void }
      def show
        render json: LibrarySerializer.list_json([ library ]).first
      end

      sig { void }
      def create
        created = Library.create!(library_params)
        ScanLibraryJob.perform_later(created.id)
        render json: LibrarySerializer.list_json([ created ]).first, status: :created
      end

      sig { void }
      def update
        library.update!(library_params)
        ScanLibraryJob.perform_later(library.id) if library.saved_change_to_roots?
        render json: LibrarySerializer.list_json([ library ]).first
      end

      sig { void }
      def destroy
        library.destroy!
        head :no_content
      end

      # Full scan, or a targeted one with `path` (a Sonarr/yt-dlp post-hook
      # names the folder it just wrote).
      sig { void }
      def scan
        path = params[:path].presence&.to_s
        if path && library.root_for(path).nil?
          return render_errors("#{path} isn't inside #{library.name}'s folders")
        end

        ScanLibraryJob.perform_later(library.id, path)
        head :accepted
      end

      # Tries TMDB again for everything in this library not yet matched.
      sig { void }
      def rematch
        RematchLibrariesJob.perform_later(library.household_id, library.id)
        head :accepted
      end

      # The folders fog mounts that no library reads yet, with the kind their
      # Drive folder suggests and the library they would join
      # (Libraries::FogSuggestions). An admin adds them; nothing is assumed.
      sig { void }
      def fog_suggestions
        render json: Libraries::FogSuggestions.new(current_household!.id).call.map { |s|
          { root: s.root, name: s.name, kind: s.kind, library_id: s.library_id, library_name: s.library_name }
        }
      end

      # Checks a folder before it's saved as a root, so the form can say
      # what's wrong while the person is still typing.
      sig { void }
      def validate_path
        render json: StorageLocation.inspect_path(params.require(:path).to_s, writable: false).to_h
      end

      private

      sig { returns(ActionController::Parameters) }
      def library_params
        params.require(:library).permit(:name, :kind, :metadata_language, roots: [])
      end
    end
  end
end
