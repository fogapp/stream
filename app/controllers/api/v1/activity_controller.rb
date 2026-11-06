# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class ActivityController < BaseController
      before_action :require_grown_up!

      sig { void }
      def index
        scope = household_entries
        if (severity = Activity::Severity.try_deserialize(params[:severity].to_s))
          scope = scope.where(severity: severity.serialize)
        end
        rows = paginate(scope.recent).includes(:subject)
        render json: rows.map { |e| ActivityEntrySerializer.entry_json(e) }
      end

      private

      sig { returns(T.untyped) }
      def household_entries
        ActivityEntry.where(household_id: [ current_household!.id, nil ])
      end
    end
  end
end
