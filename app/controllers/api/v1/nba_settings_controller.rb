# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › NBA League Pass (PROPOSAL §7.8): on or off,
    # with nothing to fill in. Its test reads NBA's schedule.
    class NbaSettingsController < IntegrationSettingsController
      private

      sig { returns(T.untyped) }
      def setting_class = NbaSetting

      sig { returns(T::Hash[String, T.untyped]) }
      def permitted = {}

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = IntegrationSettingSerializer.nba_json(setting)

      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = Nba::Schedule.new

      sig { returns(String) }
      def unsaved_message = "Turn on NBA League Pass first."
    end
  end
end
