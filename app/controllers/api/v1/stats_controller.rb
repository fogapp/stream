# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Now playing, history and the month in numbers (PROPOSAL §7.4). Admins.
    class StatsController < BaseController
      before_action :require_admin!

      sig { void }
      def now_playing
        render json: Stats::Watching.now_playing
      end

      sig { void }
      def history
        scope = PlaybackSession.watched.order(started_at: :desc)
        scope = scope.where(profile_id: params[:profile_id].to_s) if params[:profile_id].present?
        render json: Stats::Watching.history(paginate(scope, default_per: 50))
      end

      sig { void }
      def summary
        render json: Stats::Watching.summary(days: params[:days].to_i.clamp(7, 365).then { |days| days == 7 && params[:days].blank? ? 30 : days })
      end
    end
  end
end
