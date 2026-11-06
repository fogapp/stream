# typed: strict
# frozen_string_literal: true

# Intro and credits for one season (PROPOSAL §5.5). Queued a few minutes
# after an episode is filed, so a season arriving at once is compared once
# its neighbours are there; cached fingerprints make repeats cheap.
class DetectMarkersJob < ApplicationJob
  extend T::Sig

  queue_as :heavy
  # A season of whole-episode reads, which stand still while someone watches
  # (HoldHeavyWhileWatchingJob) and are given up on only when they stop
  # advancing: hours, on a slow share.
  limits_concurrency to: 1, key: ->(show_id, season_number) { "markers:#{show_id}:#{season_number}" }, duration: 12.hours
  # A whole-file read that ran out of time met a share in trouble: one more
  # try, an hour later, not two straight away (each re-reads the whole file
  # and starved playback on 2026-10-08). Its AnalysisRun records the failure.
  retry_on ToolRunner::Timeout, wait: 1.hour, attempts: 2
  retry_on Markers::Fingerprinter::ReadFailed, wait: 1.hour, attempts: 2
  discard_on Markers::Fingerprinter::Unavailable

  sig { params(show_id: String, season_number: Integer).void }
  def perform(show_id, season_number)
    show = Show.unscoped.find_by(id: show_id)
    return if show.nil?

    Markers::Detector.detect_season(show, season_number, hold: HoldHeavyWhileWatchingJob.hold)
  end

  sig { override.params(error: Exception).returns(T::Boolean) }
  def report_death?(error) = !error.is_a?(Markers::Fingerprinter::Unavailable)
end
