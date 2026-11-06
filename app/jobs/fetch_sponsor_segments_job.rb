# typed: strict
# frozen_string_literal: true

# A video's SponsorBlock segments (PROPOSAL §5.4), replaced wholesale: the
# community votes segments in and out, so what we hold follows theirs.
class FetchSponsorSegmentsJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(video_id) { "sponsorblock:#{video_id}" }
  retry_on UpstreamHttpClient::RateLimitError, wait: 5.minutes, attempts: 5

  sig { params(video_id: String).void }
  def perform(video_id)
    video = Video.unscoped.find_by(id: video_id)
    youtube_id = video&.youtube_id
    return if video.nil? || youtube_id.nil? || !video.library&.sponsorblock

    found = Youtube::SponsorBlock.new.segments(youtube_id)
    SponsorSegment.transaction do
      SponsorSegment.where(video: video).delete_all
      now = Time.current
      rows = found.map do |segment|
        { video_id: video.id, category: segment[:category].serialize, start_seconds: segment[:start], end_seconds: segment[:end],
          uuid: segment[:uuid], created_at: now, updated_at: now }
      end
      SponsorSegment.insert_all!(rows) if rows.any? # rubocop:disable Rails/SkipsModelValidations
      video.update_columns(sponsorblock_checked_at: now) # rubocop:disable Rails/SkipsModelValidations
    end
  rescue Youtube::SponsorBlock::Error => e
    raise if e.connection?

    Rails.logger.warn("SponsorBlock for #{video_id}: #{e.message}")
  end
end
