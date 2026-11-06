# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › Immich (PROPOSAL §5.4). The key is write-only.
    class ImmichSettingsController < IntegrationSettingsController
      sig { void }
      def sync
        return render_errors("Set up Immich first") unless ImmichSetting.exists?(household: current_household!)

        ImmichSyncJob.perform_later(current_household!.id)
        head :accepted
      end

      private

      sig { returns(T.untyped) }
      def setting_class = ImmichSetting

      sig { returns(T::Hash[String, T.untyped]) }
      def permitted = params.require(:immich_setting).permit(:url, :api_key, :immich_path_prefix, :local_path_prefix, :enabled).to_h

      sig { returns(T::Hash[String, Symbol]) }
      def write_only = { "api_key" => :once_saved }

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = IntegrationSettingSerializer.immich_json(setting)

      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = Immich::Client.new(setting)

      sig { returns(String) }
      def unsaved_message = "Save Immich's address and key first."
    end
  end
end
