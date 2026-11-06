# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › MLB.tv (PROPOSAL §7.8): the account yt-dlp
    # signs in with. The password is write-only.
    class MlbSettingsController < IntegrationSettingsController
      private

      sig { returns(T.untyped) }
      def setting_class = MlbSetting

      sig { returns(T::Hash[String, T.untyped]) }
      def permitted = params.require(:mlb_setting).permit(:username, :password).to_h

      sig { returns(T::Hash[String, Symbol]) }
      def write_only = { "password" => :once_saved }

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = IntegrationSettingSerializer.mlb_json(setting)

      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = Mlb::Account.new(setting)

      sig { returns(String) }
      def unsaved_message = "Save an email and password first."
    end
  end
end
