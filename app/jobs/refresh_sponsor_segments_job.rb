# typed: strict
# frozen_string_literal: true

# Segments arrive after a video does: asks again, daily, for the videos in
# SponsorBlock libraries from the last month, and first for any never asked.
class RefreshSponsorSegmentsJob < ApplicationJob
  extend T::Sig

  queue_as :default

  RECENT = T.let(30.days, ActiveSupport::Duration)

  sig { void }
  def perform
    videos = Video.unscoped.joins(:library).where(libraries: { sponsorblock: true }).where.not(youtube_id: nil)
    due = videos.where(sponsorblock_checked_at: nil)
      .or(videos.where(upload_date: RECENT.ago.to_date..).where(sponsorblock_checked_at: ...1.day.ago))
    ids = due.limit(2000).pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| FetchSponsorSegmentsJob.new(id) }) if ids.any?
  end
end
