# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # One episode's analysis, for Hook: does it sound like its show?
    class EpisodesController < BaseController
      finds :episode, from: -> { Viewing::Access.episodes(Episode.where(show_id: Show.select(:id))) }
      # Analysis is the running, not the watching.
      before_action :require_grown_up!

      sig { void }
      def identity
        render json: EpisodeIdentitySerializer.json(Markers::Identity.for(episode))
      end
    end
  end
end
