# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Instance-wide settings (Settings › General). Admin-only writes.
    class AppSettingsController < BaseController
      before_action :require_admin!, only: :update

      sig { void }
      def show
        render json: SettingsSerializer.general_json(AppSetting.current, profiles: ntfy_profiles)
      end

      sig { void }
      def update
        setting = AppSetting.current
        setting.webhook_url = params[:webhook_url].to_s.strip.presence if params.key?(:webhook_url)
        setting.ntfy_url = params[:ntfy_url].to_s.strip.chomp("/").presence if params.key?(:ntfy_url)
        setting.max_video_transcodes = params[:max_video_transcodes].presence&.to_i if params.key?(:max_video_transcodes)
        assign_optimize(setting)
        setting.time_zone = params[:time_zone].to_s.strip.presence if params.key?(:time_zone)
        # What's out of range is the model's to say (AppSetting's validations).
        return render_errors(setting) unless setting.valid?

        zone_changed = setting.time_zone_changed?
        webhook_changed = setting.webhook_url_changed?
        setting.save!
        AppSetting.bust_cache!
        # Never the webhook's address (its path is a secret): that it changed.
        Activity.record(source: "settings", event: "general.changed",
          summary: "General settings changed by #{current_user!.name}#{webhook_changed ? ' (webhook changed)' : ''}",
          payload: setting.slice(:max_video_transcodes, :ntfy_url, :optimize_automatically,
            :optimize_quiet_start_hour, :optimize_quiet_end_hour, :optimize_max_height, :optimize_budget_gb, :time_zone)
            .merge("webhook_changed" => webhook_changed))
        # The Grid's 8pm moved: every channel's schedule is rebuilt to match.
        ActiveJob.perform_all_later(Station.pluck(:id).map { |id| ScheduleStationJob.new(id, true) }) if zone_changed
        render json: SettingsSerializer.general_json(setting, profiles: ntfy_profiles)
      end

      private

      # Whose ntfy topics this user may see: an admin sees every profile's.
      sig { returns(T::Array[Profile]) }
      def ntfy_profiles
        current_user!.admin? ? Profile.order(:position, :created_at).to_a : []
      end

      # Optimized versions (PROPOSAL §5.5): when, how tall, how much room.
      # Whole numbers only: "3.5" or "12abc" is no hour, rather than 3 or 12.
      sig { params(setting: AppSetting).void }
      def assign_optimize(setting)
        setting.optimize_automatically = bool_param(:optimize_automatically) if params.key?(:optimize_automatically)
        setting.optimize_paused = bool_param(:optimize_paused) if params.key?(:optimize_paused)
        setting.fetch_trailers = bool_param(:fetch_trailers) if params.key?(:fetch_trailers)
        %i[optimize_quiet_start_hour optimize_quiet_end_hour optimize_budget_gb].each do |key|
          setting.public_send(:"#{key}=", Integer(params[key].to_s, exception: false)) if params.key?(key)
        end
        setting.optimize_max_height = params[:optimize_max_height].to_i if params.key?(:optimize_max_height)
      end
    end
  end
end
