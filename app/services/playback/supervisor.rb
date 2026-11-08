# typed: strict
# frozen_string_literal: true

module Playback
  # The transcoder process's brain (PROPOSAL §3.2, §6.3): one ffmpeg run per
  # streaming session, started where the viewer is and restarted when they
  # seek somewhere it won't reach soon. Runs are stopped when their session
  # ends or goes quiet, and the cache is kept inside its budget. A session
  # placed on a remote transcoder is supervised the same way, through
  # TranscodeRun rows its worker picks up (Runner); if that node goes quiet
  # the session carries on here.
  class Supervisor
    extend T::Sig

    # A requested GOP the live run will reach within this long is waited
    # for; further off, the run starts again there (docs/PERF_PROPOSAL.md
    # › P16). A restart costs about this much before its first GOP.
    WAIT_FOR = 1.0
    # What a run starting on a far GOP is assumed to cover before it has
    # produced anything to measure: the next segment or two, not a seek.
    # In film time, or in GOPs if that's further: a film's GOPs can be ten
    # seconds each, and a run slow to start (a cold file on the NAS) was
    # killed for the fragment after its first, then started again for the
    # one it had been about to make.
    STARTING_REACH_MS = 10_000
    STARTING_REACH_GOPS = 2
    # A resend (Signal) for another GOP than the session last asked for, this
    # soon after, is a request the player has given up on: it was answered
    # by moving the run away from where the viewer now is, and the two
    # fought over ffmpeg until the abandoned one timed out (§6, baseline).
    SUPERSEDED_FOR = 10.0
    # A session nobody has fetched from in this long has its run stopped.
    IDLE = T.let(2.minutes, ActiveSupport::Duration)
    # A run asked for a GOP it hasn't made, and making nothing at all for
    # this long, is stuck (a stalled NAS read, a hung decoder or GPU):
    # killed and started again. Before
    # its first output it gets longer: opening a cold file over the share.
    STALL_AFTER = 10.0
    FIRST_OUTPUT_WITHIN = 25.0
    # A run that failed is started again once; a second failure this soon
    # after is the session's (transcode_error), not a hiccup.
    RETRY_WINDOW = 120.0
    # A run this far past what the player last asked for is paused (SIGSTOP)
    # until the player catches up to within the second (SIGCONT), or asks
    # for something further. -readrate
    # alone let a run make the rest of the film at twice real time.
    # Above every player's own buffer goal (the web's 60 s, the Apple TV's
    # 60 s: docs/APPLETV_STALLS.md › R4), so a player keeping its buffer
    # full never finds itself at the run's frontier.
    AHEAD_PAUSE_MS = 180_000
    AHEAD_RESUME_MS = 120_000

    # The last place a session (or one of its versions) asked for, and when.
    class Wanted < T::Struct
      const :gop, Integer
      const :at, Float
    end

    # A restart held back a moment, in case a later request supersedes it.
    class Pending < T::Struct
      const :session_id, String
      const :variant, Integer
      const :gop, Integer
      const :due, Float
      # When it was first held back for a cold run on its share (hold_for_share).
      const :held_since, T.nilable(Float), default: nil
    end

    # A channel tuned ahead waits while a run someone is watching is still
    # cold on the same slow share — until it has made this many GOPs, or
    # for at most HOLD_AT_MOST (docs/APPLETV_STALLS.md › R1).
    COLD_GOPS = 3
    HOLD_AT_MOST = 15.0
    HOLD_EVERY = 1.0

    sig do
      params(encoder: Encoders::Kind, log: T.proc.params(message: String).void, debounce: Float).void
    end
    def initialize(encoder: Encoders.kind, log: ->(message) { Rails.logger.info("[transcoder] #{message}") }, debounce: 0.0)
      @profile = T.let(Encoders::Profile.local(encoder), Encoders::Profile)
      @log = log
      @runs = T.let({}, T::Hash[String, Run])
      @wanted = T.let({}, T::Hash[String, Wanted])
      @pending = T.let({}, T::Hash[String, Pending])
      # How long a restart waits for a later one to replace it (bin/transcoder
      # sets 50 ms; specs start at once).
      @debounce = debounce
      @running_ids = T.let(Set.new.freeze, T::Set[String])
      # Where each stream's player last had to ask (its directory: GOP),
      # replaced whole so the sweep's thread reads a snapshot.
      @asked = T.let({}.freeze, T::Hash[String, Integer])
      @sweep = T.let(CacheSweep.new(running: -> { @running_ids }, asked: -> { @asked }), CacheSweep)
      @publishing = T.let(RunPublishing.new, RunPublishing)
      # When each run key last failed (monotonic): one restart, then the error.
      @failed_at = T.let({}, T::Hash[String, Float])
    end

    sig { returns(T::Hash[String, Run]) }
    attr_reader :runs

    # Make sure something is producing this GOP of this session (or of one
    # of its smaller versions). A resend for somewhere the session has since
    # stopped asking for is ignored. A restart that has to happen waits
    # @debounce for a later request to replace it.
    sig { params(session_id: String, gop: Integer, variant: Integer, resent: T::Boolean).void }
    def request(session_id, gop, variant = 0, resent: false)
      return if Cache.gop_ready?(session_id, gop, variant)

      run_key = key(session_id, variant)
      now = monotonic
      wanted = @wanted[run_key]
      return if resent && wanted && wanted.gop != gop && now - wanted.at < SUPERSEDED_FOR

      unless resent
        @wanted[run_key] = Wanted.new(gop: gop, at: now)
        @asked = @asked.merge(Cache.directory(session_id, variant).to_s => gop).freeze
      end
      session = PlaybackSession.unscoped.find_by(id: session_id)
      return if session.nil? || !session.active? || !session.method_enum.streamed?
      # Given up on (fail_run): its error stands, and the player falls back
      # a rung (Playback::Fallback) rather than this trying a third time.
      failed = @failed_at[run_key]
      return if failed && now - failed < RETRY_WINDOW && session.transcode_error && !@runs.key?(run_key)

      version = Variants.find(session, variant)
      return if version.nil?

      plan = SegmentPlan.for(session)
      gop = gop.clamp(0, plan.gop_count - 1)
      run = @runs[run_key]
      # Asked for anything: going again, and paused later if still far ahead.
      resume(run) if run&.paused
      if run && run.handle.alive? && run.reaches?(gop, plan)
        # Answered by the run already going: nothing to restart.
        @pending.delete(run_key)
        return
      end

      if @debounce.positive?
        @pending[run_key] = Pending.new(session_id: session_id, variant: variant, gop: gop, due: now + @debounce)
      elsif !hold_for_share(session, variant, gop)
        start(session, plan, gop, version)
      end
    end

    # A channel tuned ahead (standby), from a slow share on which a run
    # someone is watching hasn't made its first GOPs yet: held back a
    # moment, so the one on screen has the share to itself while it starts.
    # Held at most HOLD_AT_MOST, then started whatever.
    sig { params(session: PlaybackSession, variant: Integer, gop: Integer, held_since: T.nilable(Float)).returns(T::Boolean) }
    def hold_for_share(session, variant, gop, held_since: nil)
      return false unless session.standby

      now = monotonic
      return false if held_since && now - held_since >= HOLD_AT_MOST

      pace = Pace.for(session)
      return false unless pace.slow? && cold_on?(T.must(pace.root), except: session.id)

      @pending[key(session.id, variant)] = Pending.new(session_id: session.id, variant: variant, gop: gop, due: now + HOLD_EVERY,
        held_since: held_since || now)
      true
    end

    # Some run on this root that someone is watching is still starting.
    sig { params(root: String, except: String).returns(T::Boolean) }
    def cold_on?(root, except:)
      @runs.values.any? do |run|
        run.session_id != except && !run.pace.standby && run.pace.root == root && !run.handle.remote? && run.handle.alive? &&
          run.advance_frontier(run.plan&.gop_count) - run.start_gop < COLD_GOPS
      end
    end

    # Restarts whose moment has come: each for the last place asked. And
    # runs the publishing thread found fault with: stopped, and why recorded.
    sig { void }
    def drain
      settle_faults
      now = monotonic
      @pending.values.select { |pending| pending.due <= now }.each do |pending|
        @pending.delete(key(pending.session_id, pending.variant))
        session = PlaybackSession.unscoped.find_by(id: pending.session_id)
        next if session.nil? || !session.active?

        version = Variants.find(session, pending.variant)
        next if version.nil?

        plan = SegmentPlan.for(session)
        next if hold_for_share(session, pending.variant, pending.gop, held_since: pending.held_since)

        start(session, plan, pending.gop, version)
      end
    end

    # Called from the publishing thread (RunPublishing).
    sig { void }
    def publish_ready = @publishing.publish_ready

    # Keeps the cache inside its budget, from the sweep's own thread.
    sig { void }
    def sweep = @sweep.call

    # Seconds until the next held restart is due, for the loop's wait.
    sig { returns(T.nilable(Float)) }
    def next_due_in
      due = @pending.values.map(&:due).min
      due && [ due - monotonic, 0.0 ].max
    end

    # Housekeeping, every few seconds: reap finished runs, stop idle ones.
    # Clearing the cache is the sweep's, on a thread of its own
    # (bin/transcoder), so a seek never waits behind a walk of it.
    sig { void }
    def tick
      reap
      measure_shares
      throttle
      watch_output
      stop_idle
      end_abandoned_standby
      now = monotonic
      @wanted.reject! { |_, wanted| now - wanted.at > SUPERSEDED_FOR }
      forget_asked
    end

    # This machine converting video for someone watching right now.
    sig { returns(T::Boolean) }
    def busy? = @runs.values.any? { |run| run.video && !run.handle.remote? && run.handle.alive? }

    # Every run of a session, its smaller versions' too.
    sig { params(session_id: String).void }
    def stop(session_id)
      @runs.select { |_, run| run.session_id == session_id }.each_key { |run_key| stop_run(run_key) }
    end

    sig { void }
    def stop_all
      @runs.keys.each { |run_key| stop_run(run_key) }
    end

    private

    sig { params(session_id: String, variant: Integer).returns(String) }
    def key(session_id, variant) = variant.zero? ? session_id : "#{session_id}:v#{variant}"

    sig { void }
    def forget_asked
      going = @runs.values.to_set { |run| Cache.directory(run.session_id, run.variant).to_s }
      @asked = @asked.select { |directory, _| going.include?(directory) }.freeze if @asked.size > going.size
    end

    # Stops a run on purpose (a seek, the session over), or for a failure
    # already recorded on its row.
    sig { params(run_key: String).void }
    def stop_run(run_key)
      run = @runs.delete(run_key)
      return if run.nil?

      Runner.kill(run.handle)
      publish_running
      discard(run)
      RunRecord.close(run, log: @log, failure: nil)
    end

    # What a run left unpublished goes with it.
    sig { params(run: Run).void }
    def discard(run)
      FileUtils.rm_rf(run.staging)
    rescue SystemCallError
      nil
    end

    sig { params(run_key: String, run: Run).returns(String) }
    def watch_key(run_key, run) = "#{run_key}@#{run.clock}"

    sig { void }
    def publish_running
      @running_ids = @runs.values.map(&:session_id).to_set.freeze
      @publishing.watch(@runs.filter_map do |run_key, run|
        publisher = run.publisher
        next if publisher.nil?

        RunPublishing::Watch.new(key: watch_key(run_key, run), session_id: run.session_id, variant: run.variant, start_gop: run.start_gop,
          staging: run.staging, publisher: publisher)
      end)
    end

    # A run whose fragments weren't the plan's: stopped, with why on the
    # session (what a waiting request answers with) and in Activity.
    sig { void }
    def settle_faults
      @publishing.each_fault do |fault|
        run_key, run = @runs.find { |name, candidate| watch_key(name, candidate) == fault.key }
        next if run_key.nil? || run.nil?

        refused(run_key, run, "#{fault.message}\n#{RunRecord.log_tail(run)}")
        stop_run(run_key)
        give_up(run.session_id, run.variant, "The stream's fragments weren't what was planned: #{fault.message}")
      end
    end

    # What it made can't be served, and another run of the same file would
    # make the same: no second try, until RETRY_WINDOW says it's a new evening.
    sig { params(run_key: String, run: Run, tail: T.nilable(String)).void }
    def refused(run_key, run, tail)
      RunRecord.close(run, log: @log, failure: TranscodeRun::Failure::Refused, tail: tail)
      Glass.increment("transcoder.failures", tags: { failure: TranscodeRun::Failure::Refused.serialize })
      @failed_at[run_key] = monotonic
    end

    sig { returns(Float) }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f

    sig { params(session: PlaybackSession, plan: SegmentPlan, gop: Integer, version: Variants::Variant).void }
    def start(session, plan, gop, version)
      launch(session, plan, gop, version)
    rescue StandardError => e
      # Never got going — its arguments, its spawn: the session says so
      # rather than every request waiting out its 20 s.
      Rails.error.report(e, handled: true, source: "transcoder")
      RunRecord.unstartable(session, version.index, gop, @profile.kind, e)
      give_up(session.id, version.index, "ffmpeg couldn't be started: #{e.message}")
    end

    sig { params(session: PlaybackSession, plan: SegmentPlan, gop: Integer, version: Variants::Variant).void }
    def launch(session, plan, gop, version)
      variant = version.index
      stop_run(key(session.id, variant))
      directory = Cache.directory(session.id, variant)
      FileUtils.mkdir_p(directory)
      # Smaller versions are converted here, never on a remote transcoder.
      node = variant.zero? ? session.transcode_node : nil
      smaller = version.original? ? nil : version
      if node && !node.online?
        # Its transcoder went away: carry on here.
        session.update_columns(transcode_node_id: nil) # rubocop:disable Rails/SkipsModelValidations
        node = nil
      end
      # A run here writes into a directory of its own, and what it finishes
      # is published from there (Publisher); a remote one's worker uploads.
      staging = T.let(nil, T.nilable(Pathname))
      record = T.let(nil, T.nilable(TranscodeRun))
      log_from = T.let(0, Integer)
      pace = Pace.for(session, converting: !smaller.nil? || !session.video_copy?)
      handle =
        if node
          Runner.start_remote(node, session: session, attributes: { encoder: node.profile.kind.serialize, start_gop: gop, variant: variant }) do |source|
            FfmpegArgs.build(session, plan, start_gop: gop, directory: Pathname.new(Runner::OUT), profile: node.profile, input: source, pace: pace)
          end
        else
          @sweep.ensure_room!
          staging = Cache.staging(session.id, SecureRandom.hex(4), variant)
          FileUtils.mkdir_p(staging)
          profile = profile_for(session)
          argv = FfmpegArgs.build(session, plan, start_gop: gop, directory: staging, profile: profile, variant: smaller, pace: pace)
          log = directory.join("ffmpeg.log")
          log_from = log.file? ? log.size : 0
          spawned = Runner.spawn_local(argv, log: log)
          record = TranscodeRun.create!(playback_session_id: session.id, state: TranscodeRun::State::Running.serialize,
            argv: argv, encoder: profile.kind.serialize, start_gop: gop, variant: variant, started_at: Time.current)
          spawned
        end
      # Its uploads are published as they arrive (NodeLink), from here.
      staging ||= Cache.staging(session.id, handle.run_id, variant)
      publisher = handle.remote? ? nil : Publisher.new(session_id: session.id, variant: variant, plan: plan)
      @runs[key(session.id, variant)] = Run.new(session_id: session.id, variant: variant, handle: handle, start_gop: gop,
        video: !smaller.nil? || session.method_enum == PlaybackSession::Method::VideoTranscode,
        frontier: gop, clock: monotonic, staging: staging, publisher: publisher,
        record_id: record&.id || handle.run_id, log_from: log_from, progressed_at: monotonic, plan: plan, pace: pace)
      publish_running
      if variant.zero?
        session.update_columns(run_start: gop, transcode_error: nil) # rubocop:disable Rails/SkipsModelValidations
      end
      where = node ? "on #{node.name}" : "ffmpeg #{handle.pid}"
      version_label = smaller ? " at #{smaller.height}p" : ""
      paced = pace.throttled && (pace.standby || pace.slow?) ? ", reading #{pace.burst.round}s then #{pace.rate}x#{pace.standby ? ' (tuned ahead)' : ' (slow share)'}" : ""
      @log.call("session #{session.id}#{version_label}: #{where} from GOP #{gop} (#{plan.gop_start_ms(gop) / 1000.0}s)#{paced}")
    end

    # This machine's encoder, or its CPU for a session that fell back from a
    # hardware encoder that failed it (Playback::Fallback).
    sig { params(session: PlaybackSession).returns(Encoders::Profile) }
    def profile_for(session)
      return @profile unless session.constraints.software && @profile.kind.hardware?

      Encoders::Profile.new(kind: Encoders::Kind::Software, tonemap_filter: @profile.tonemap_filter)
    end

    # A run that exited: fine if it reached the end, a recorded error if not.
    sig { void }
    def reap
      @runs.dup.each do |run_key, run|
        exit = Runner.poll(run.handle)
        next if exit.nil?

        session_id = run.session_id
        # The last of what it wrote, before it's forgotten.
        @publishing.finish(watch_key(run_key, run))
        @runs.delete(run_key)
        publish_running
        discard(run)
        tail = exit.message || RunRecord.log_tail(run)
        if exit.offline
          RunRecord.close(run, log: @log, failure: TranscodeRun::Failure::Lost, tail: tail)
          # The next request for a GOP starts it again here.
          PlaybackSession.unscoped.where(id: session_id).update_all(transcode_node_id: nil) # rubocop:disable Rails/SkipsModelValidations
          @log.call("session #{session_id}: #{exit.message}; carrying on here")
          next
        end
        # Its session already says why (NodeLink).
        next refused(run_key, run, tail) if exit.failure == TranscodeRun::Failure::Refused

        if exit.success?
          # Done before it could be measured: it read at the share's speed
          # all the way, if its whole film was inside the burst.
          ShareMeasure.call(run, finished: true) unless run.measured
          RunRecord.close(run, log: @log, failure: nil, status: 0, tail: tail)
        elsif exit.signal
          # Nothing here sends a signal to a run it still lists: it crashed.
          fail_run(run_key, run, TranscodeRun::Failure::Crashed, "ffmpeg was killed by SIG#{::Signal.signame(T.must(exit.signal))}",
            signal: exit.signal, tail: tail)
        elsif exit.status
          fail_run(run_key, run, TranscodeRun::Failure::Exited, "ffmpeg exited #{exit.status}", status: exit.status, tail: tail)
        elsif exit.failure
          fail_run(run_key, run, T.must(exit.failure), remote_failure(T.must(exit.failure), exit.message), tail: tail)
        else
          RunRecord.close(run, log: @log, failure: nil, tail: tail)
        end
      end
    end

    # Why a remote run stopped, when it couldn't report a code.
    sig { params(failure: TranscodeRun::Failure, message: T.nilable(String)).returns(String) }
    def remote_failure(failure, message)
      failure == TranscodeRun::Failure::Lost && message ? message : "ffmpeg was killed on its transcoder"
    end

    # Pauses a run far ahead of what its player has asked for, and lets it
    # go again when the player nears it: a paused or abandoned play no
    # longer converts the rest of the film, nor fills the cache with it.
    sig { void }
    def throttle
      @runs.each do |run_key, run|
        plan = run.plan
        wanted = @wanted[run_key]
        next if run.handle.remote? || plan.nil? || wanted.nil?

        run.advance_frontier(plan.gop_count)
        ahead = plan.gop_start_ms([ run.frontier, plan.gop_count - 1 ].min) - plan.gop_start_ms([ wanted.gop, plan.gop_count - 1 ].min)
        if !run.paused && ahead > AHEAD_PAUSE_MS
          run.handle.pause
          run.paused = true
        elsif run.paused && ahead < AHEAD_RESUME_MS
          resume(run)
        end
      end
    end

    # Each run here, once, while it is still inside its burst: how fast its
    # share delivered the film it has made (ShareSpeed). A run past its
    # burst by then read at least that fast, which counts only when it's
    # enough to call the share fast.
    sig { void }
    def measure_shares
      @runs.each_value { |run| ShareMeasure.call(run) unless run.measured || run.paused }
    end

    sig { params(run: Run).void }
    def resume(run)
      run.handle.resume
      run.paused = false
      # Its silence while paused wasn't a stall.
      run.progressed_at = monotonic
    end

    # The watchdog: a run asked for a GOP it hasn't made, that has made
    # nothing at all for too long, is stuck — however near the estimate
    # (Run#reaches?) says the GOP is. Every resend would otherwise be
    # answered by waiting on it, and the player by 503s until it gave up.
    sig { void }
    def watch_output
      now = monotonic
      @runs.dup.each do |run_key, run|
        next if run.paused

        mark = output_mark(run)
        if mark != run.output_mark
          run.output_mark = mark
          run.progressed_at = now
          next
        end
        wanted = @wanted[run_key]
        next if wanted.nil? || wanted.gop < run.start_gop || Cache.gop_ready?(run.session_id, wanted.gop, run.variant)

        limit = run.frontier > run.start_gop || staged_anything?(run) ? STALL_AFTER : FIRST_OUTPUT_WITHIN
        next if now - run.progressed_at < limit

        fail_run(run_key, run, TranscodeRun::Failure::Stalled, "ffmpeg made nothing for #{limit.to_i} s", tail: RunRecord.log_tail(run))
      end
    end

    # What changes whenever a run makes something: its staging directory
    # (a fragment renamed in, or published out), how far its GOPs reach,
    # and for a remote run what its worker last reported.
    sig { params(run: Run).returns(String) }
    def output_mark(run)
      staged = run.staging.directory? ? run.staging.mtime.to_f : nil
      run.advance_frontier(run.plan&.gop_count)
      [ staged, run.frontier, run.handle.progress_seconds ].join(":")
    end

    sig { params(run: Run).returns(T::Boolean) }
    def staged_anything?(run)
      run.staging.directory? && run.staging.children.any? { |path| path.basename.to_s.match?(/\A(gop|open|done|skip)-/) }
    rescue SystemCallError
      false
    end

    # A run that failed: recorded, then started again where it was wanted —
    # once. A second failure this soon is the session's, and the player is
    # told (Segments).
    sig do
      params(run_key: String, run: Run, failure: TranscodeRun::Failure, detail: String,
        status: T.nilable(Integer), signal: T.nilable(Integer), tail: T.nilable(String)).void
    end
    def fail_run(run_key, run, failure, detail, status: nil, signal: nil, tail: nil)
      RunRecord.close(run, log: @log, failure: failure, status: status, signal: signal, tail: tail)
      Glass.increment("transcoder.failures", tags: { failure: failure.serialize })
      now = monotonic
      last = @failed_at[run_key]
      @failed_at[run_key] = now
      gop = [ @wanted[run_key]&.gop, run.frontier ].compact.max || run.frontier
      session = PlaybackSession.unscoped.find_by(id: run.session_id)
      version = session && Variants.find(session, run.variant)
      if (last.nil? || now - last > RETRY_WINDOW) && session&.active? && version
        @log.call("session #{run.session_id}: #{detail}; starting again at GOP #{gop}")
        start(session, SegmentPlan.for(session), gop, version)
      else
        stop_run(run_key)
        last_line = tail.to_s.strip.lines.last.to_s.strip
        give_up(run.session_id, run.variant, [ detail, last_line.presence ].compact.uniq.join(": "))
      end
    end

    # What the session's waiting requests answer with, and Activity.
    sig { params(session_id: String, variant: Integer, message: String).void }
    def give_up(session_id, variant, message)
      @log.call("session #{session_id}: #{message}")
      # A smaller version failing leaves the original playing; the player
      # moves to another version when its own requests time out.
      return unless variant.zero?

      PlaybackSession.unscoped.find_by(id: session_id)&.transcode_failed!(message)
    end

    # A Grid channel tuned ahead on a page nobody has had open for a
    # while (PlaybackSession::IDLE_AFTER): ended, so its token stops working
    # and it's off every list of what's playing. A play of its own is left
    # alone however long it's paused — resuming it must still work.
    sig { void }
    def end_abandoned_standby
      PlaybackSession.unscoped.where(state: PlaybackSession::State::Active.serialize, standby: true)
        .where(last_seen_at: ...PlaybackSession::IDLE_AFTER.ago).find_each(&:end!)
    end

    sig { void }
    def stop_idle
      return if @runs.empty?

      ids = @runs.values.map(&:session_id).uniq
      # A channel tuned ahead fetches nothing once prerolled: its run is
      # kept (paused by the throttle once far enough ahead) until its
      # session ends, untouched for half an hour (end_abandoned_standby).
      # Stopping it after IDLE made switching to it a cold start
      # (docs/APPLETV_STALLS.md › R3).
      # One read: which are still there, and of those which have gone quiet.
      found = PlaybackSession.unscoped.where(id: ids)
        .pluck(:id, Arel.sql(PlaybackSession.sanitize_sql_array([ "state = ? OR (last_seen_at < ? AND NOT standby)",
          PlaybackSession::State::Ended.serialize, IDLE.ago ])))
      quiet = found.filter_map { |id, idle| id if idle }
      gone = ids - found.map(&:first)
      (quiet + gone).each do |session_id|
        @log.call("session #{session_id}: stopping idle run")
        stop(session_id)
      end
    end
  end
end
