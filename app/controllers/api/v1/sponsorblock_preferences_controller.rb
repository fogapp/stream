# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # What the watching profile does about each SponsorBlock category
    # (PROPOSAL §5.4): skip it, ask, or just show it on the timeline.
    class SponsorblockPreferencesController < BaseController
      sig { void }
      def show
        render json: { actions: SponsorSegment.actions_for(current_profile!) }
      end

      # { actions: { category => action } }
      sig { void }
      def update
        given = params.fetch(:actions, {}).permit(*SponsorSegment::DEFAULT_ACTIONS.keys).to_h
        valid = given.select { |_, action| SponsorSegment::Action.try_deserialize(action.to_s) }
        profile = current_profile!
        profile.update!(sponsorblock: profile.sponsorblock.merge(valid))
        show
      end
    end
  end
end
