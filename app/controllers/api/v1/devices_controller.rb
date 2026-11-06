# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # What the household's screens can play, for hook to weigh a release
    # before it downloads one: a film every device decodes directly is
    # worth preferring over one that would need a video transcode.
    class DevicesController < BaseController
      # Longer than Device.recent: a TV used for films is seen less often.
      SEEN_WITHIN = T.let(90.days, ActiveSupport::Duration)

      sig { void }
      def capabilities
        devices = Device.where(last_seen_at: SEEN_WITHIN.ago..).order(last_seen_at: :desc)
        render json: devices.map { |device| DeviceSerializer.capabilities_json(device) }
      end
    end
  end
end
