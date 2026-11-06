# typed: strict
# frozen_string_literal: true

# Pauses the heavy queue while anyone is watching, and resumes it once
# nobody is. Trickplay, subtitles and loudness each read a whole file over
# the NAS; on 2026-10-08 a backlog of them held the fog VM at 73% I/O
# pressure and the transcoder couldn't read a remux as fast as it played
# (Groundhog Day stalled every few seconds on the Grid). Playback comes
# first; the backlog waits for an idle house.
#
# A pause stops new heavy jobs being claimed, and a read already running
# stands still (ToolRunner's hold, which asks holding?) until it's lifted.
# This job owns the heavy queue's pause: one set by hand is lifted the next
# time nobody is watching.
class HoldHeavyWhileWatchingJob < ApplicationJob
  extend T::Sig

  queue_as :control
  limits_concurrency to: 1, key: -> { "hold_heavy_while_watching" }

  QUEUE = "heavy"
  # A playing player reports every ten seconds; a paused one stops. This
  # long without a report and the session isn't being watched.
  WATCHING_WITHIN = T.let(2.minutes, ActiveSupport::Duration)

  sig { void }
  def perform
    queue = SolidQueue::Queue.find_by_name(QUEUE)
    if self.class.watching?
      queue.pause unless queue.paused?
    elsif queue.paused?
      queue.resume
    end
  end

  # Whether a heavy read should stand still right now: the queue's pause,
  # which this job keeps in step with the house. Read past the query cache:
  # the read asking runs inside a job, where the cache is on, and a held
  # read writes nothing that would clear it — so the first "paused" was its
  # answer for good, and the read never resumed (both heavy threads stood
  # still from 15:30 on 2026-10-21 until a deploy killed them).
  sig { returns(T::Boolean) }
  def self.holding? = SolidQueue::Pause.uncached { SolidQueue::Queue.find_by_name(QUEUE).paused? }

  # As a ToolRunner hold, for the reads on the heavy queue.
  sig { returns(ToolRunner::Hold) }
  def self.hold = -> { holding? }

  # Someone has a play going: on screen, not a Grid neighbour on standby.
  sig { returns(T::Boolean) }
  def self.watching?
    PlaybackSession.unscoped.watched.where(state: PlaybackSession::State::Active.serialize)
      .exists?(last_seen_at: WATCHING_WITHIN.ago..)
  end
end
