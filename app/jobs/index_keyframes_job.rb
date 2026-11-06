# typed: strict
# frozen_string_literal: true

# The keyframe index for one file (PROPOSAL §5.3): the container's own index
# on the analyze queue in a few KB, or — when there isn't one — the packet
# scan, which reads the whole file, handed to the heavy queue.
class IndexKeyframesJob < ApplicationJob
  extend T::Sig

  queue_as :analyze
  # A play's scan has a key of its own. The semaphore is taken at dispatch, so
  # a scan waiting on the heavy queue, which stands still while someone
  # watches, holds its key for as long as that lasts: shared, it would keep
  # the very play that paused it from being indexed (invariant 3). Scanning
  # twice costs a read; the second finds the index there and stops.
  limits_concurrency to: 1, key: ->(media_file_id, _scan = false) { "keyframes:#{media_file_id}:#{queue_name.to_s == Media::KeyframeIndex::PLAY_QUEUE ? 'play' : 'background'}" },
    duration: 12.hours
  # A whole-file read that stalled for minutes met a share in trouble: one
  # more try, later, not two straight away. A damaged file reads the same
  # way every time — its AnalysisRun says so in Needs attention.
  retry_on ToolRunner::Timeout, wait: 1.hour, attempts: 2

  # Someone's play stalled this recently: the share needs its reads more
  # than this does.
  YIELD_TO_STALLS = T.let(60.seconds, ActiveSupport::Duration)
  # The one read over this file (Media::OnePass) is under way, and makes the
  # index itself if it can: looked at again once it's likely done.
  BUSY_WAIT = T.let(30.minutes, ActiveSupport::Duration)

  sig { params(media_file_id: String, scan: T::Boolean).void }
  def perform(media_file_id, scan = false)
    file = MediaFile.unscoped.find_by(id: media_file_id)
    return if file.nil? || file.state_enum != MediaFile::State::Probed || file.primary_video.nil?

    if scan
      # Indexed meanwhile: by the one read over the file (Media::OnePass),
      # which collects keyframes from the thumbnails' decode, or a scan
      # that got there first.
      return unless file.keyframes.nil?
      return retry_job(wait: YIELD_TO_STALLS) if PlaybackEvent.where(kind: PlaybackEvent::Kind::Stall.serialize, created_at: YIELD_TO_STALLS.ago..).exists?

      # On the heavy queue, the read stands still while someone watches and
      # waits its turn behind the one read over the file. A play's own scan
      # (the index queue) does neither: someone's waiting on it, and that
      # read may itself be standing still for them.
      return Media::KeyframeIndex.scan!(file, hold: nil) unless queue_name.to_s == HoldHeavyWhileWatchingJob::QUEUE

      done = Media::OnePass.exclusively(file) { Media::KeyframeIndex.scan!(file, hold: HoldHeavyWhileWatchingJob.hold) }
      retry_job(wait: BUSY_WAIT) if done.nil?
      return
    end

    Media::KeyframeIndex.scan_later(file) if Media::KeyframeIndex.index_from_container!(file).nil?
  end
end
