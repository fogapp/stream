# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › TMDB (PROPOSAL §5.2). The key is write-only:
    # the response says whether one is set, never what it is. Everyone may
    # see whether TMDB is connected (Settings shows it to every member); an
    # admin sets, clears and tests the key.
    class TmdbSettingsController < IntegrationSettingsController
      skip_before_action :require_admin!, only: :show

      private

      sig { returns(T.untyped) }
      def setting_class = TmdbSetting

      sig { returns(T::Hash[String, T.untyped]) }
      def permitted
        key = params.require(:tmdb_setting).permit(:api_key)[:api_key].to_s.strip
        { "api_key" => key.presence }
      end

      sig { returns(T::Hash[String, Symbol]) }
      def write_only = { "api_key" => :always_kept }

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = TmdbSettingSerializer.setting_json(setting)

      # A first key: everything filed so far went in under its file name.
      sig { params(setting: T.untyped).void }
      def saved(setting)
        RematchLibrariesJob.perform_later(current_household!.id) if setting.configured? && setting.api_key_before_last_save.blank?
      end

      sig { params(setting: T.untyped).returns(T::Boolean) }
      def testable?(setting) = setting.configured?

      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = Tmdb::Client.new(api_key: setting.api_key.to_s)

      sig { returns(String) }
      def unsaved_message = "Enter a TMDB key first."
    end
  end
end
