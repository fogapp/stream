# typed: strict
# frozen_string_literal: true

# One subtitle track a viewer picked, taken out of its file
# (docs/APPLETV_STALLS.md › R5): MediaController#subtitle asks for it and
# waits a moment, the player asks again until it's there. The same track
# asked for twice is one job (discarded on conflict), and a file is read for
# one track at a time.
class ExtractSubtitleTrackJob < ApplicationJob
  extend T::Sig

  queue_as :subtitles
  limits_concurrency to: 1, key: ->(media_file_id, track_id, extension) { "subtitle:#{media_file_id}:#{track_id}:#{extension}" },
    duration: 2.hours, on_conflict: :discard

  sig { params(media_file_id: String, track_id: String, extension: String).void }
  def perform(media_file_id, track_id, extension)
    file = MediaFile.unscoped.find_by(id: media_file_id)
    return if file.nil?

    track = Subtitles::Tracks.find(file, track_id)
    return if track.nil? || !Subtitles::Extractor.extensions_for(track).include?(extension)

    Subtitles::Extractor.extract_for_viewer(file, track, extension)
  rescue Subtitles::Extractor::Error, ToolRunner::Error => e
    # Written beside the track (Extractor.failed), and the request that
    # waits on it says so to the player: nothing to retry here.
    Rails.logger.warn("[subtitles] #{media_file_id} #{track_id}.#{extension}: #{e.message}")
  end
end
