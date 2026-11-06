# typed: strict
# frozen_string_literal: true

module Playback
  # How fast a run's share delivered the film it has made (ShareSpeed),
  # read once, while the run is still inside its burst.
  module ShareMeasure
    extend T::Sig

    # A run is measured once it has read this long inside its burst.
    MEASURE_AFTER = 2.0
    # A remote run's first GOP has a poll, a cold open and an upload to get
    # through, and a seconds-old reading of it would say nothing.
    REMOTE_MEASURE_AFTER = 20.0

    # A run past its burst by then read at least that fast, which counts
    # only when it's enough to call the share fast.
    sig { params(run: Supervisor::Run, finished: T::Boolean).void }
    def self.call(run, finished: false)
      root = run.pace.root
      bitrate = run.pace.bitrate
      plan = run.plan
      elapsed = run.elapsed
      return if root.nil? || bitrate.nil? || plan.nil? || !elapsed.positive?

      after = run.handle.remote? ? REMOTE_MEASURE_AFTER : MEASURE_AFTER
      return if !finished && elapsed < after

      last = plan.gop_count - 1
      done_ms = (finished ? plan.gop_end_ms(last) : plan.gop_start_ms([ run.advance_frontier(plan.gop_count), last ].min)) -
        plan.gop_start_ms(run.start_gop)
      # Nothing yet (a cold open over the share): look again, a while.
      return if !finished && !done_ms.positive? && elapsed < after * 3

      run.measured = true
      return unless done_ms.positive?
      return remote(run, root, done_ms / 1000.0, bitrate, elapsed) if run.handle.remote?

      # Its burst over already: what it managed is only a floor, worth
      # keeping when the floor alone says the share isn't slow.
      return if run.pace.throttled && done_ms >= run.pace.burst * 1000 && run.pace.burst / elapsed < Pace::SLOW_HEADROOM

      ShareSpeed.record(root, done_ms / 1000.0 * bitrate / elapsed)
    end

    # A remote run only sets a floor (ShareSpeed.floor). More film than its
    # pace lets it read by now means it ran into GOPs already made, which
    # says nothing of the share.
    sig { params(run: Supervisor::Run, root: String, film: Float, bitrate: Float, elapsed: Float).void }
    def self.remote(run, root, film, bitrate, elapsed)
      return if film > run.pace.burst + (run.pace.rate * elapsed)

      ShareSpeed.floor(root, film * bitrate / elapsed)
    end
    private_class_method :remote
  end
end
