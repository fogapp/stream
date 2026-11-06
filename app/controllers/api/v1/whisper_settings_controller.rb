# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › Whisper (PROPOSAL §5.5): where channel videos
    # without subtitles are transcribed. The key, if any, is write-only.
    class WhisperSettingsController < IntegrationSettingsController
      private

      sig { returns(T.untyped) }
      def setting_class = WhisperSetting

      sig { returns(T::Hash[String, T.untyped]) }
      def permitted = params.require(:whisper_setting).permit(:url, :api_kind, :model, :api_key, :enabled).to_h

      sig { returns(T::Hash[String, Symbol]) }
      def write_only = { "api_key" => :always_kept }

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = IntegrationSettingSerializer.whisper_json(setting)

      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = Transcripts::WhisperClient.new(setting)

      sig { returns(String) }
      def unsaved_message = "Save Whisper's address first."
    end
  end
end
