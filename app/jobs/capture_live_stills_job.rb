# typed: strict
# frozen_string_literal: true

# Every live stream's card picture, a few minutes old at most (PROPOSAL
# §7.8): fans out one CaptureLiveStillJob per stream (CLAUDE.md invariant 8).
class CaptureLiveStillsJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { void }
  def perform
    ids = LiveStream.unscoped.added.pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| CaptureLiveStillJob.new(id) })
  end
end
