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
        if params.key?(:ntfy_url)
          url = params[:ntfy_url].to_s.strip.chomp("/").presence
          return render_errors("ntfy's address starts with http:// or https://") if url && !url.match?(%r{\Ahttps?://\S+\z})

          setting.ntfy_url = url
        end
        if params.key?(:max_video_transcodes)
          cap = params[:max_video_transcodes].presence&.to_i
          return render_errors("The limit must be between 1 and 8") if cap && !cap.between?(1, 8)

          setting.max_video_transcodes = cap
        end
        error = assign_optimize(setting)
        return render_errors(error) if error

        setting.time_zone = params[:time_zone].to_s.strip.presence if params.key?(:time_zone)
        return render_errors(setting.errors.full_messages) unless setting.valid?

        zone_changed = setting.time_zone_changed?
        setting.save!
        AppSetting.bust_cache!
        Activity.record(source: "settings", event: "general.changed",
          summary: "General settings changed by #{current_user!.name}",
          payload: setting.slice(:webhook_url, :max_video_transcodes, :ntfy_url, :optimize_automatically,
            :optimize_quiet_start_hour, :optimize_quiet_end_hour, :optimize_max_height, :optimize_budget_gb, :time_zone))
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
      sig { params(setting: AppSetting).returns(T.nilable(String)) }
      def assign_optimize(setting)
        setting.optimize_automatically = bool_param(:optimize_automatically) if params.key?(:optimize_automatically)
        setting.optimize_paused = bool_param(:optimize_paused) if params.key?(:optimize_paused)
        setting.fetch_trailers = bool_param(:fetch_trailers) if params.key?(:fetch_trailers)
        %i[optimize_quiet_start_hour optimize_quiet_end_hour].each do |key|
          next unless params.key?(key)

          hour = T.let(Integer(params[key].to_s, exception: false), T.nilable(Integer))
          return "Quiet hours run from one hour of the day (0–23) to another" if hour.nil? || !hour.between?(0, 23)

          setting.public_send(:"#{key}=", hour)
        end
        if params.key?(:optimize_max_height)
          height = params[:optimize_max_height].to_i
          return "Optimized versions are 720p, 1080p or 2160p" unless [ 720, 1080, 2160 ].include?(height)

          setting.optimize_max_height = height
        end
        if params.key?(:optimize_budget_gb)
          budget = T.let(Integer(params[:optimize_budget_gb].to_s, exception: false), T.nilable(Integer))
          return "The space for optimized versions is between 1 and 100000 GB" if budget.nil? || !budget.between?(1, 100_000)

          setting.optimize_budget_gb = budget
        end
        nil
      end
    end
  end
end
