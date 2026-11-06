# typed: strict
# frozen_string_literal: true

# Looks up which YouTube video each of a channel's hand-placed videos is
# (Youtube::Identifier). On the youtube queue: it asks YouTube for the
# channel's whole list, as a download would.
class IdentifyChannelVideosJob < ApplicationJob
  extend T::Sig

  queue_as :youtube
  limits_concurrency to: 1, key: ->(channel_id) { "identify_channel:#{channel_id}" }, duration: 30.minutes

  sig { params(channel_id: String).void }
  def perform(channel_id)
    channel = Channel.unscoped.find_by(id: channel_id)
    return if channel.nil?

    Youtube::Identifier.new(channel).call
  rescue Youtube::YtDlp::Error => e
    # The videos stay unchecked, so the next hourly look tries again.
    Activity.record(source: "youtube", event: "channel.identify_failed", severity: Activity::Severity::Warn, subject: channel,
      household_id: channel&.household_id, summary: "Couldn't look up #{channel&.title}'s videos on YouTube: #{e.message.truncate(200)}")
  end
end
