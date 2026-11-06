# typed: strict
# frozen_string_literal: true

# Every hour, each channel YouTube knows that has videos nobody has looked
# up yet (Youtube::Identifier). Fans out only.
class IdentifyVideosJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { void }
  def perform
    waiting = Video.unscoped.where(youtube_id: nil, identity: Video::Identity::Unchecked.serialize).select(:channel_id)
    ids = Channel.unscoped.where.not(youtube_id: nil).where(id: waiting).pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| IdentifyChannelVideosJob.new(id) }) if ids.any?
  end
end
