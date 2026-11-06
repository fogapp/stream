# typed: strict
# frozen_string_literal: true

# One ffmpeg run of a playback session, here or on a remote transcoder,
# and every run handed to a remote
# transcoder (TranscodeNode). A remote run's argv has {server} and {out} for
# the worker to fill in; the transcoder writes pending and stopping, and the
# worker's polls move it to running and exited. A run here is running until
# it exits or is stopped. Either way the row keeps how it ended and the end
# of what ffmpeg said, after the cache that held its log is swept.
class TranscodeRun < ApplicationRecord
  extend T::Sig

  class State < T::Enum
    include ApplicationEnum
    enums do
      # Waiting for the node's next poll.
      Pending = new("pending")
      Running = new("running")
      # The transcoder wants it stopped; the node kills it on its next poll.
      Stopping = new("stopping")
      Exited = new("exited")
    end
  end

  # How a run failed. A run stopped on purpose (a seek, the session ending)
  # has none.
  class Failure < T::Enum
    include ApplicationEnum
    enums do
      # ffmpeg exited with an error.
      Exited = new("exited")
      # Killed by a signal nobody here sent: a segfault, the OOM killer.
      Crashed = new("crashed")
      # Asked for something and produced nothing for too long (Supervisor).
      Stalled = new("stalled")
      # Made something that couldn't be served (Publisher::Mismatch).
      Refused = new("refused")
      # Never got going: its arguments couldn't be built, or it couldn't spawn.
      Unstartable = new("unstartable")
      # Its remote transcoder went away mid-run.
      Lost = new("lost")
    end
  end

  # What ffmpeg said that is kept on the row: the end of it.
  LOG_TAIL = 16_000

  belongs_to :transcode_node, optional: true
  belongs_to :playback_session, optional: true
  belongs_to :optimized_version, optional: true

  attribute :state, State
  attribute :failure, Failure, allow_nil: true

  scope :live, -> { where(state: [ State::Pending, State::Running, State::Stopping ].map(&:serialize)) }
  scope :remote, -> { where.not(transcode_node_id: nil) }
  scope :failed, -> { where.not(failure: nil) }

  # What the run reads: the session's or the version's original.
  sig { returns(T.nilable(MediaFile)) }
  def media_file = playback_session&.media_file || optimized_version&.media_file

  sig { params(status: T.nilable(Integer), log_tail: T.nilable(String), failure: T.nilable(Failure)).void }
  def exited!(status, log_tail = nil, failure: nil)
    assign_attributes(state: State::Exited.serialize, exit_status: status, log_tail: log_tail&.last(LOG_TAIL), finished_at: Time.current)
    self.failure = failure.serialize if failure
    save!
  end

  # How a run here ended, or why it's counted a failure.
  sig do
    params(failure: T.nilable(Failure), status: T.nilable(Integer), signal: T.nilable(Integer), log_tail: T.nilable(String)).void
  end
  def finished!(failure:, status: nil, signal: nil, log_tail: nil)
    update!(state: State::Exited.serialize, failure: failure, exit_status: status, signal: signal,
      log_tail: log_tail&.last(LOG_TAIL) || self.log_tail, finished_at: finished_at || Time.current)
  end
end
