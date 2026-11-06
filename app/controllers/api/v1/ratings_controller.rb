# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # This profile's stars for a title (PROPOSAL §7.4).
    class RatingsController < BaseController
      # { rateable_type, rateable_id, value: 1–10, or empty to clear }
      sig { void }
      def update
        rateable = find_rateable
        value = params[:value].presence&.to_f
        if value.nil?
          removed = Rating.where(profile: current_profile!, rateable: rateable).delete_all
          Trakt::Outbox.rated(current_profile!.id, rateable, nil) if removed.positive?
          return render json: { value: nil }
        end

        rating = Rating.find_or_initialize_by(profile: current_profile!, rateable: rateable)
        rating.assign_attributes(value: value, rated_at: Time.current)
        return render_errors("Ratings go from half a star to five") unless rating.save

        Trakt::Outbox.rated(current_profile!.id, rateable, rating.value)
        render json: { value: rating.value }
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      private

      sig { returns(T.any(Movie, Show, Episode)) }
      def find_rateable
        T.cast(Viewing::Playables.find!(params.require(:rateable_type), params.require(:rateable_id), only: %w[movie show episode]),
          T.any(Movie, Show, Episode))
      end
    end
  end
end
