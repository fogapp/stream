# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › TMDB (PROPOSAL §5.2). The key is write-only:
    # the response says whether one is set, never what it is.
    class TmdbSettingsController < BaseController
      before_action :require_admin!, except: :show

      sig { void }
      def show
        render json: TmdbSettingSerializer.setting_json(setting)
      end

      sig { void }
      def update
        was_configured = setting.configured?
        key = params.require(:tmdb_setting).permit(:api_key)[:api_key].to_s.strip
        setting.update!(api_key: key.presence)
        # A first key: everything filed so far went in under its file name.
        RematchLibrariesJob.perform_later(current_household!.id) if !was_configured && setting.configured?
        render json: TmdbSettingSerializer.setting_json(setting)
      end

      sig { void }
      def test
        client = Tmdb::Client.for(current_household!)
        return render json: { ok: false, message: "Enter a TMDB key first." } if client.nil?

        client.configuration
        setting.record_test!(true, "Connected to TMDB.")
        render json: { ok: true, message: "Connected to TMDB." }
      rescue UpstreamHttpClient::Error => e
        setting.record_test!(false, e.message)
        render json: { ok: false, message: e.message }
      end

      private

      sig { returns(TmdbSetting) }
      def setting
        @setting ||= T.let(TmdbSetting.for_household!(current_household!), T.nilable(TmdbSetting))
      end
    end
  end
end
