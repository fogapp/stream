# typed: strict
# frozen_string_literal: true

# Every household with Immich switched on, synced (PROPOSAL §5.4). Only fans
# out.
class ImmichSyncsJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { void }
  def perform
    ids = ImmichSetting.unscoped.where(enabled: true).pluck(:household_id)
    ActiveJob.perform_all_later(ids.map { |id| ImmichSyncJob.new(id) })
  end
end
