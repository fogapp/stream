# typed: strict
# frozen_string_literal: true

# One read of a probed file for every whole-file step it still needs
# (Media::OnePass): thumbnails, keyframes, loudness, subtitles. On the heavy
# queue, which waits while anyone watches — and the read itself stands
# still while they do; one at a time per file; and patient with a share in
# trouble.
class AnalyzeMediaFileJob < ApplicationJob
  extend T::Sig

  queue_as :heavy
  # Hours, for a remux on a slow share: the semaphore outlives the read,
  # and ReclaimOrphanedSemaphoresJob frees one a dead worker left behind.
  limits_concurrency to: 1, key: ->(media_file_id) { "analysis:#{media_file_id}" }, duration: 12.hours
  # A read that stood still for minutes met a share in trouble: one more
  # try, an hour later, not two straight away (each re-reads the whole file
  # and starved playback on 2026-10-08). Its AnalysisRuns record the failure.
  retry_on ToolRunner::Timeout, wait: 1.hour, attempts: 2

  # Another read of the same file is under way past its semaphore: look
  # again once it's likely done, when
  # there may be nothing left to do.
  BUSY_WAIT = T.let(30.minutes, ActiveSupport::Duration)

  sig { params(media_file_id: String).void }
  def perform(media_file_id)
    file = MediaFile.unscoped.includes(:media_streams).find_by(id: media_file_id)
    return if file.nil? || file.state_enum != MediaFile::State::Probed

    done = Media::OnePass.exclusively(file) { Media::OnePass.run(file, hold: HoldHeavyWhileWatchingJob.hold) }
    return retry_job(wait: BUSY_WAIT) if done.nil?
    return unless done.include?(AnalysisRun::Step::Subtitles)

    # With the subtitles out, the transcript is a read away; and any
    # language still missing can be fetched.
    BuildTranscriptJob.perform_later(file.id)
    FetchSubtitlesJob.perform_later(file.id)
  end
end
