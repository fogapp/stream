# typed: strict
# frozen_string_literal: true

# Syncs one household with Immich (PROPOSAL §5.4).
class ImmichSyncJob < ApplicationJob
  extend T::Sig

  queue_as :sync
  limits_concurrency to: 1, key: ->(household_id) { "immich_sync:#{household_id}" }, duration: 1.hour

  sig { params(household_id: String).void }
  def perform(household_id)
    setting = ImmichSetting.unscoped.find_by(household_id: household_id)
    Immich::Sync.new(setting).call if setting&.enabled
  end
end
