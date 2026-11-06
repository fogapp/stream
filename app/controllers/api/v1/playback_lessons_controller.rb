# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # What plays have taught: each rung
    # that failed for a file on a kind of client, which decisions now skip
    # until it's tried again — and Forget, for an admin who knows better.
    class PlaybackLessonsController < BaseController
      before_action :require_admin!
      finds :playability, from: -> { Playability.all }
      skip_before_action :set_playability, only: :index

      sig { void }
      def index
        scope = Playability.where.not(last_failed_at: nil).includes(:media_file).order(last_failed_at: :desc)
        render json: paged(scope) { |rows| rows.map { |row| PlaybackLessonSerializer.row_json(row) } }
      end

      sig { void }
      def destroy
        playability.destroy!
        head :no_content
      end
    end
  end
end
