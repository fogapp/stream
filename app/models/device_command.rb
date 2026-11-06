# typed: strict
# frozen_string_literal: true

# Something asked of a device that can be played to (PROPOSAL §11 Phase 6):
# picked up on its next poll, and worthless a minute later — "pause" an
# hour late is worse than not at all.
class DeviceCommand < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  LIFETIME = T.let(1.minute, ActiveSupport::Duration)

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      # payload: kind, id (the playable), title, profile_token (optional)
      Play = new("play")
      Pause = new("pause")
      Resume = new("resume")
      Stop = new("stop")
      # payload: seconds (absolute) or by (relative)
      Seek = new("seek")
      # A Grid channel (PROPOSAL §7.7). payload: number, station_id, name,
      # profile_token (optional)
      Tune = new("tune")
    end
  end

  belongs_to :device
  belongs_to :user, optional: true

  attribute :kind, Kind

  scope :waiting, -> { where(delivered_at: nil).where(expires_at: Time.current..) }
end
