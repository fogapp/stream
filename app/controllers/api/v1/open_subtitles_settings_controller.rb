# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › OpenSubtitles (PROPOSAL §5.5). The key and
    # password are write-only.
    class OpenSubtitlesSettingsController < IntegrationSettingsController
      private

      sig { returns(T.untyped) }
      def setting_class = OpenSubtitlesSetting

      sig { returns(T::Hash[String, T.untyped]) }
      def permitted = params.require(:open_subtitles_setting).permit(:api_key, :username, :password, :enabled, languages: []).to_h

      sig { returns(T::Hash[String, Symbol]) }
      def write_only = { "api_key" => :once_saved, "password" => :always_kept }

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = IntegrationSettingSerializer.open_subtitles_json(setting)

      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = Subtitles::OpenSubtitles.new(setting)

      sig { returns(String) }
      def unsaved_message = "Save an API key first."
    end
  end
end
