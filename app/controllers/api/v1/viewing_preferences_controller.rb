# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # How the watching profile likes to watch (PROPOSAL §7.4) — the choices
    # that are its own to make, not an admin's restrictions.
    class ViewingPreferencesController < BaseController
      sig { void }
      def show
        render json: preferences_json
      end

      # { autoplay_videos }
      sig { void }
      def update
        current_profile!.update!(autoplay_videos: bool_param(:autoplay_videos)) if params.key?(:autoplay_videos)
        render json: preferences_json
      end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def preferences_json
        { autoplay_videos: current_profile!.autoplay_videos }
      end
    end
  end
end
