# typed: strict
# frozen_string_literal: true

# Fans out a poll to every tracked channel that's due (PROPOSAL §5.4).
class PollChannelsJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { void }
  def perform
    ids = Channel.unscoped.due_for_poll.pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| PollChannelJob.new(id) }) if ids.any?
  end
end
