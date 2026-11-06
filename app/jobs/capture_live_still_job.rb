# typed: strict
# frozen_string_literal: true

# One live stream's card picture (LiveStreams::Still), and — when it had to
# ask the source — whether the source is there (PROPOSAL §7.8): online and
# seen now, or offline with why, as its card and the Playback page say.
class CaptureLiveStillJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(stream_id) { "live_still:#{stream_id}" }, duration: 2.minutes, on_conflict: :discard

  sig { params(stream_id: String).void }
  def perform(stream_id)
    stream = LiveStream.unscoped.find_by(id: stream_id)
    return if stream.nil?

    return unless LiveStreams::Still.capture!(stream) == :source

    stream.update_columns(status: LiveStream::Status::Online.serialize, last_seen_at: Time.current, last_error: nil, # rubocop:disable Rails/SkipsModelValidations
      last_error_at: nil, consecutive_failures: 0, updated_at: Time.current)
  rescue LiveStreams::Prober::Failure => e
    LiveStreams::Prober.offline!(stream, e.message) if stream
  end
end
