# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Dry runs and imports from Plex (PROPOSAL §7.4).
    class PlexImportsController < BaseController
      before_action :require_admin!

      sig { void }
      def index
        render json: PlexImport.order(created_at: :desc).limit(10).map { |import| PlexSerializer.import_json(import) }
      end

      sig { void }
      def create
        unless PlexConnection.exists?(household_id: current_household!.id)
          return render_errors("Connect a Plex server first")
        end

        import = PlexImport.create!(dry_run: bool_param(:dry_run, default: true))
        PlexImportJob.perform_later(import.id)
        render json: PlexSerializer.import_json(import), status: :created
      end
    end
  end
end
