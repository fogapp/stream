# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # One program in the Grid guide (PROPOSAL §7.7): being reminded of it.
    class AiringsController < BaseController
      finds :airing, from: -> { Airing.all }

      sig { void }
      def remind
        raise ActiveRecord::RecordNotFound unless Viewing::Access.allows?(airing.station)
        return render_errors("That has already started", status: :conflict) if airing.starts_at <= Time.current

        reminder = AiringReminder.create_with(user: current_user!, created_at: Time.current)
          .find_or_create_by!(profile: current_profile!, airing: airing)
        RemindAiringJob.set(wait_until: [ airing.starts_at - AiringReminder::BEFORE, Time.current ].max).perform_later(reminder.id)
        head :no_content
      rescue ActiveRecord::RecordNotUnique
        head :no_content
      end

      sig { void }
      def forget
        AiringReminder.where(profile: current_profile!, airing: airing).delete_all
        head :no_content
      end
    end
  end
end
