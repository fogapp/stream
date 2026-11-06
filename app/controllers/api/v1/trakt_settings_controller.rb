# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › Trakt (PROPOSAL §7.4): the household's Trakt
    # API app. The secret is write-only.
    class TraktSettingsController < IntegrationSettingsController
      # Every profile's link goes with the app it was made through.
      sig { void }
      def destroy
        TraktAccount.where(household: current_household!).delete_all
        super
      end

      private

      sig { returns(T.untyped) }
      def setting_class = TraktSetting

      sig { returns(T::Hash[String, T.untyped]) }
      def permitted = params.require(:trakt_setting).permit(:client_id, :client_secret).to_h

      sig { returns(T::Hash[String, Symbol]) }
      def write_only = { "client_secret" => :once_saved }

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = TraktSerializer.setting_json(setting)

      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = Trakt::Client.new(setting)

      sig { returns(String) }
      def unsaved_message = "Save a client ID and secret first."
    end
  end
end
