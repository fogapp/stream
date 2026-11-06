# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Marking something watched or unwatched, and dismissing a Continue
    # watching or Next up card (PROPOSAL §7.1).
    class WatchStatesController < BaseController
      sig { void }
      def create
        state = Playback::Progress.mark(current_profile!, playable, watched: bool_param(:watched, default: true))
        render json: { watched: state.completed?, play_count: state.play_count }
      end

      sig { void }
      def hide
        WatchState.hide_from_home(current_profile!, playable)
        head :no_content
      end

      private

      sig { returns(T.any(Movie, Episode, Video, Clip)) }
      def playable
        T.cast(Viewing::Playables.find!(params.require(:playable_type), params.require(:playable_id), only: %w[movie episode video clip]),
          T.any(Movie, Episode, Video, Clip))
      end
    end
  end
end
