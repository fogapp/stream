# typed: strict
# frozen_string_literal: true

# Fingerprints and probes one file (PROPOSAL §5.3). Keyed per file so a
# rescan while a probe is queued never probes the same file twice at once.
class ProbeMediaFileJob < ApplicationJob
  extend T::Sig

  queue_as :scan
  limits_concurrency to: 1, key: ->(media_file_id) { "probe_media_file:#{media_file_id}" }
  # A share too busy to answer in time: the file isn't broken, so it's
  # probed again later rather than marked so.
  retry_on ToolRunner::Timeout, wait: 15.minutes, attempts: 4
  # A read the share refused (EIO, EACCES) may well pass later.
  retry_on SystemCallError, wait: 15.minutes, attempts: 4

  ALREADY_READ = T.let([ MediaFile::State::Probed, MediaFile::State::Broken ].freeze, T::Array[MediaFile::State])

  sig { params(media_file_id: String).void }
  def perform(media_file_id)
    media_file = MediaFile.unscoped.find_by(id: media_file_id)
    # Each hourly scan queues again whatever's still waiting, so a first
    # scan longer than an hour leaves duplicates behind: only the first has
    # anything to do. Rerun and a changed file both put it back to Discovered.
    return if media_file.nil? || ALREADY_READ.include?(media_file.state_enum)

    outcome = Media::FileProber.new(media_file).call
    # A moved file keeps its title; only new content needs filing.
    return unless outcome == Media::FileProber::Outcome::Probed

    media_file.reload
    # The whole-file read, a couple at a time on the heavy queue: a new
    # arrival's ahead of the back catalogue's. One insert for all three.
    ActiveJob.perform_all_later([
      MatchMediaFileJob.new(media_file.id, media_file.library_id),
      IndexKeyframesJob.new(media_file.id),
      AnalyzeMediaFileJob.new(media_file.id).set(priority: Media::AnalysisPriority.for(media_file))
    ])
    Markers::Detector.from_chapters(media_file)
  end
end
