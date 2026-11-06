# typed: strict
# frozen_string_literal: true

# Checks one tracked channel for new videos (PROPOSAL §5.4).
class PollChannelJob < ApplicationJob
  extend T::Sig

  queue_as :sync
  limits_concurrency to: 1, key: ->(channel_id) { "youtube_poll:#{channel_id}" }, duration: 1.hour

  sig { params(channel_id: String).void }
  def perform(channel_id)
    channel = Channel.unscoped.find_by(id: channel_id)
    return if channel.nil? || !channel.tracked

    Youtube::Poller.new(channel).call
  end
end
