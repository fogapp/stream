# typed: strict
# frozen_string_literal: true

module Playback
  class Supervisor
    # One ffmpeg run the Supervisor keeps: a session's (or one of its smaller
    # versions'), here or on a remote transcoder, and the estimate of how
    # soon it will reach a GOP that decides whether a request waits for it
    # or starts it again.
    class Run < T::Struct
      extend T::Sig

      const :session_id, String
      # 0: the session's own stream; n: its smaller version n (Variants).
      const :variant, Integer, default: 0
      prop :handle, Runner::Handle
      prop :start_gop, Integer
      # Converting video, not just repackaging: what optimizing gives way to.
      prop :video, T::Boolean, default: false
      # The first GOP it hasn't finished, as last seen: only ever moves on.
      prop :frontier, Integer
      # Monotonic seconds when it started, for how fast it's going.
      prop :clock, Float
      # Where what it makes lands before it's published (Publisher): its
      # ffmpeg's output here, its worker's uploads for a remote run — which
      # NodeLink publishes as they arrive, so it has no publisher of its own.
      const :staging, Pathname
      const :publisher, T.nilable(Publisher), default: nil
      # Its TranscodeRun: the row a run here writes, or a remote run's own.
      const :record_id, T.nilable(String), default: nil
      # Where its part of the session's ffmpeg.log begins.
      const :log_from, Integer, default: 0
      # When it last made anything, in monotonic seconds, and what that
      # looked like (output_mark): the watchdog's evidence.
      prop :progressed_at, Float, default: 0.0
      prop :output_mark, T.nilable(String), default: nil
      # Paused far ahead of the player (throttle), and the plan it runs to.
      prop :paused, T::Boolean, default: false
      const :plan, T.nilable(SegmentPlan), default: nil
      # How fast it reads (Pace): what reaches? reckons with, the root
      # it reads from, and whether its burst has been measured (ShareSpeed).
      const :pace, Pace, default: Pace.new(rate: FfmpegArgs.readrate, burst: FfmpegArgs.readrate_burst)
      prop :measured, T::Boolean, default: false

      # Seconds since it started.
      sig { returns(Float) }
      def elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - clock

      # The run's first GOP not in the cache yet (up to `limit`, the plan's
      # end): everything before it the run has made.
      sig { params(limit: T.nilable(Integer)).returns(Integer) }
      def advance_frontier(limit)
        self.frontier += 1 while (limit.nil? || frontier < limit) && Cache.gop_ready?(session_id, frontier, variant)
        frontier
      end

      # Whether it will reach this GOP within WAIT_FOR, from how fast it has
      # gone so far — which only holds to the end of its initial burst: past
      # that it reads at the throttle's rate (FfmpegArgs), however fast the
      # disk let the burst go. A fixed count of GOPs, at twice real time,
      # could mean a twelve-second wait; a burst's speed carried past the
      # burst called a seek a minute ahead a second away.
      sig { params(gop: Integer, plan: SegmentPlan).returns(T::Boolean) }
      def reaches?(gop, plan)
        return false if gop < start_gop

        # Behind where it has got to: there, or swept (CacheSweep), and if
        # swept this run will never come back for it.
        return Cache.gop_ready?(session_id, gop, variant) if gop < advance_frontier(plan.gop_count)

        start_ms = plan.gop_start_ms(start_gop)
        done_ms = plan.gop_start_ms([ frontier, plan.gop_count - 1 ].min) - start_ms
        target_ms = plan.gop_start_ms(gop) - start_ms
        # Nothing made yet to measure: a request just past where it began is
        # the next segment or two; anything further is a seek.
        return target_ms <= STARTING_REACH_MS || gop - start_gop <= STARTING_REACH_GOPS if done_ms <= 0 || elapsed < 0.25

        measured = [ done_ms / 1000.0 / elapsed, 0.01 ].max
        # Unthrottled, it goes on as it has gone.
        return (target_ms - done_ms) / 1000.0 / measured <= WAIT_FOR unless pace.throttled

        burst_ms = pace.burst * 1000
        in_burst_ms = [ [ target_ms, burst_ms ].min - done_ms, 0.0 ].max
        throttled_ms = [ target_ms - [ done_ms, burst_ms ].max, 0.0 ].max
        (in_burst_ms / 1000.0 / measured) + (throttled_ms / 1000.0 / pace.rate) <= WAIT_FOR
      end
    end
  end
end
