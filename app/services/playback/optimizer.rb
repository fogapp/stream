# typed: strict
# frozen_string_literal: true

module Playback
  # Encodes optimized versions (PROPOSAL §5.5) from inside the transcoder
  # process, because that's where the hardware encoder is and where live
  # load is known. One at a time, niced, only in quiet hours (or when an
  # admin said "now"), and it gives way the moment the machine doing it has
  # to convert video for someone watching: the version goes back in the
  # queue and starts over next time. An idle remote transcoder with a
  # hardware encoder takes the work when there is one (Placement).
  class Optimizer
    extend T::Sig

    # How often a running encode records its progress and says it's alive.
    HEARTBEAT = T.let(10.seconds, ActiveSupport::Duration)
    # An encode nobody has heard from in this long lost its transcoder.
    STALE = T.let(5.minutes, ActiveSupport::Duration)
    # Longer than any film takes to encode, even in software without AVX2.
    TIMEOUT = T.let(12.hours, ActiveSupport::Duration)
    # A slow share can take longer than that just to read a remux: such a
    # file gets its reading time and half as much again, up to this, or it
    # would run out of time and start over for ever.
    READ_MARGIN = 1.5
    LONGEST = T.let(3.days, ActiveSupport::Duration)

    class Job < T::Struct
      prop :version_id, String
      prop :media_file_id, String
      const :handle, Runner::Handle
      prop :duration, Float
      prop :started_at, ActiveSupport::TimeWithZone
      prop :beat_at, ActiveSupport::TimeWithZone
      const :plan, OptimizeArgs::Plan
      const :timeout, Float
    end

    sig do
      params(encoder: Encoders::Kind, worker: String, log: T.proc.params(message: String).void).void
    end
    def initialize(encoder:, worker: Socket.gethostname, log: ->(message) { Rails.logger.info("[optimizer] #{message}") })
      @profile = T.let(Encoders::Profile.local(encoder), Encoders::Profile)
      @worker = worker
      @log = log
      @job = T.let(nil, T.nilable(Job))
    end

    sig { returns(T.nilable(Job)) }
    attr_reader :job

    # How long an encode of this file may take, in seconds.
    sig { params(file: MediaFile).returns(Float) }
    def self.timeout_for(file)
      root = Pace.root_of(file)
      speed = root && ShareSpeed.read(root)
      reading = speed ? file.size / speed * READ_MARGIN : 0.0
      reading.clamp(TIMEOUT.to_f, LONGEST.to_f)
    end

    # Every few seconds from the transcoder's loop. busy: this machine is
    # converting video for someone watching.
    sig { params(busy: T::Boolean).void }
    def tick(busy:)
      reclaim_stale
      job = @job
      return start_next(busy) if job.nil?

      exit = Runner.poll(job.handle)
      if exit.nil?
        reason = stop_reason(job, busy)
        reason ? interrupt(job, reason) : beat(job)
      elsif exit.offline
        interrupt(job, exit.message.to_s)
      else
        finish(job, exit)
      end
    end

    # The transcoder is shutting down: the encode goes back in the queue.
    sig { void }
    def stop
      job = @job
      interrupt(job, "the transcoder stopped") if job
    end

    private

    sig { params(busy: T::Boolean).void }
    def start_next(busy)
      node = Placement.node_for_optimize
      return if node.nil? && busy

      version = claim(node)
      return if version.nil?

      file = MediaFile.unscoped.includes(:media_streams).find_by(id: version.media_file_id)
      readable = file && file.state_enum == MediaFile::State::Probed && (node || File.file?(file.path))
      plan = readable ? OptimizeArgs.plan(file, max_height: AppSetting.cached.optimize_max_height) : nil
      if file.nil? || plan.nil?
        message = file.nil? ? "The original file is gone" : "The original can't be read or has no video"
        version.update!(state: OptimizedVersion::State::Failed.serialize, worker: nil, error: message)
        run = file && analysis(file.id)
        run&.update!(status: AnalysisRun::Status::Failed.serialize, error: message, consecutive_failures: run.consecutive_failures + 1)
        return
      end

      FileUtils.mkdir_p(OptimizedVersion.root)
      FileUtils.rm_f(version.partial_path)
      progress = progress_path(version.id)
      FileUtils.rm_f(progress)
      handle =
        if node
          # The worker uploads output.mp4 to the version's partial path.
          Runner.start_remote(node, version: version) do |source|
            OptimizeArgs.build(file, plan, output: "#{Runner::OUT}/output.mp4", progress: "#{Runner::OUT}/progress",
              profile: node.profile, input: source)
          end
        else
          args = OptimizeArgs.build(file, plan, output: "file:#{version.partial_path}", progress: "file:#{progress}", profile: @profile)
          # Niced: a live session on the same CPU always wins.
          Runner.spawn_local([ "nice", "-n", "10", *args ], log: log_path(version.id))
        end
      @job = Job.new(version_id: version.id, media_file_id: file.id, handle: handle, duration: file.duration_seconds.to_f,
        started_at: Time.current, beat_at: Time.current, plan: plan, timeout: self.class.timeout_for(file))
      analysis(file.id)&.update!(status: AnalysisRun::Status::Running.serialize, started_at: Time.current)
      @log.call("optimizing #{file.filename} (#{plan.height}p#{plan.tonemap ? ', tone-mapped' : ''}) #{node ? "on #{node.name}" : "as ffmpeg #{handle.pid}"}")
    end

    # The next version to encode, taken so no other transcoder takes it, in
    # OptimizedVersion::QUEUE_ORDER.
    sig { params(node: T.nilable(TranscodeNode)).returns(T.nilable(OptimizedVersion)) }
    def claim(node)
      setting = AppSetting.cached
      scope = OptimizedVersion.claimable(OptimizedVersion.unscoped.queued, setting, full: OptimizedVersion.bytes_used >= setting.optimize_budget_bytes)
      OptimizedVersion.transaction do
        # What's wanted soonest (an airing tonight, the next episode) ahead
        # of what's merely waiting (docs/PERF_PROPOSAL.md › P20).
        version = scope.in_queue_order.lock("FOR UPDATE SKIP LOCKED").first
        version&.update!(state: OptimizedVersion::State::Encoding.serialize, worker: node&.name || @worker, heartbeat_at: Time.current,
          started_at: Time.current, attempts: version.attempts + 1, progress: 0, error: nil,
          encoder: (node&.profile || @profile).kind.serialize)
        version
      end
    end

    sig { params(job: Job, busy: T::Boolean).returns(T.nilable(String)) }
    def stop_reason(job, busy)
      version = OptimizedVersion.unscoped.find_by(id: job.version_id)
      return "it was cancelled" if version.nil? || version.state_enum != OptimizedVersion::State::Encoding
      node_id = job.handle.node_id
      busy = TranscodeNode.find_by(id: node_id)&.live_video_sessions.to_i.positive? if node_id
      return "someone started watching something that needs converting" if busy
      return "optimizing was paused" if !version.run_now && AppSetting.cached.optimize_paused
      return "quiet hours ended" if !version.run_now && !AppSetting.cached.quiet_hours?
      return "it ran past #{job.timeout.seconds.inspect}" if job.started_at < job.timeout.seconds.ago

      nil
    end

    sig { params(job: Job).void }
    def beat(job)
      return if job.beat_at > HEARTBEAT.ago

      job.beat_at = Time.current
      OptimizedVersion.unscoped.where(id: job.version_id)
        .update_all(progress: progress_of(job), heartbeat_at: Time.current, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    sig { params(job: Job, reason: String).void }
    def interrupt(job, reason)
      # Waited for: its partial output is deleted next.
      Runner.kill(job.handle, wait: true)
      @job = nil
      version = OptimizedVersion.unscoped.find_by(id: job.version_id)
      # Not a failure: it gets its attempt back and starts over next time.
      version.interrupted!(reason) if version && version.state_enum == OptimizedVersion::State::Encoding
      FileUtils.rm_f(OptimizedVersion.partial_path_for(job.version_id))
      analysis(job.media_file_id)&.update!(status: AnalysisRun::Status::Pending.serialize)
      cleanup(job.version_id)
      @log.call("optimize paused: #{reason}")
    end

    sig { params(job: Job, exit: Runner::Exit).void }
    def finish(job, exit)
      @job = nil
      version = OptimizedVersion.unscoped.find_by(id: job.version_id)
      run = analysis(job.media_file_id)
      if version.nil?
        FileUtils.rm_f(OptimizedVersion.partial_path_for(job.version_id))
      elsif exit.success? && version.partial_path.file?
        File.rename(version.partial_path, version.path)
        version.update!(state: OptimizedVersion::State::Ready.serialize, progress: 1, size: version.path.size, worker: nil,
          height: job.plan.height, tonemapped: job.plan.tonemap && profile_of(job).tonemaps?,
          audio_stream_index: job.plan.audio_index, finished_at: Time.current)
        run&.update!(status: AnalysisRun::Status::Succeeded.serialize, finished_at: Time.current, error: nil,
          duration_ms: ((Time.current - job.started_at) * 1000).round, consecutive_failures: 0,
          tool_version: AnalysisRun.short_version(ToolRunner.version("ffmpeg")))
        @log.call("optimized version #{version.id} ready (#{(version.path.size / 1.megabyte.to_f).round} MB)")
      else
        tail = exit.message.presence || log_tail(job.version_id).presence
        tail ||= "the output never arrived" if exit.success?
        message = "ffmpeg exited #{exit.status || '?'}: #{tail || 'no output'}".truncate(500)
        FileUtils.rm_f(version.partial_path)
        failed = version.attempts >= OptimizedVersion::MAX_ATTEMPTS
        version.update!(state: (failed ? OptimizedVersion::State::Failed : OptimizedVersion::State::Queued).serialize,
          error: message, progress: 0, worker: nil)
        run&.update!(status: AnalysisRun::Status::Failed.serialize, error: message, consecutive_failures: run.consecutive_failures + 1)
        @log.call("optimize failed: #{message}")
      end
      cleanup(job.version_id)
    end

    # An encode whose transcoder went away without a word goes back in the
    # queue for any transcoder to take.
    sig { void }
    def reclaim_stale
      stale = OptimizedVersion.unscoped.where(state: OptimizedVersion::State::Encoding.serialize).where(heartbeat_at: ...STALE.ago)
      job = @job
      stale = stale.where.not(id: job.version_id) if job
      stale.find_each { |version| version.interrupted!("#{version.worker || 'its transcoder'} stopped answering", refund: false) }
    end

    sig { params(job: Job).returns(Float) }
    def progress_of(job)
      return 0.0 unless job.duration.positive?

      seconds = job.handle.progress_seconds || progress_here(job)
      (seconds / job.duration).clamp(0.0, 0.99).round(3)
    end

    # What a run here's ffmpeg last wrote to its -progress file.
    sig { params(job: Job).returns(Float) }
    def progress_here(job)
      path = progress_path(job.version_id)
      return 0.0 unless path.file?

      LogTail.read(path, bytes: 2048).scan(/^out_time_us=(\d+)/).last&.first.to_i / 1_000_000.0
    end

    sig { params(job: Job).returns(Encoders::Profile) }
    def profile_of(job)
      node = job.handle.node_id && TranscodeNode.find_by(id: job.handle.node_id)
      node ? node.profile : @profile
    end

    sig { params(media_file_id: String).returns(T.nilable(AnalysisRun)) }
    def analysis(media_file_id)
      AnalysisRun.find_or_create_by!(media_file_id: media_file_id, step: AnalysisRun::Step::Optimize.serialize)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::InvalidForeignKey
      nil
    end

    sig { params(version_id: String).returns(Pathname) }
    def progress_path(version_id) = OptimizedVersion.root.join("#{version_id}.progress")

    sig { params(version_id: String).returns(Pathname) }
    def log_path(version_id) = OptimizedVersion.root.join("#{version_id}.log")

    sig { params(version_id: String).returns(String) }
    def log_tail(version_id)
      path = log_path(version_id)
      path.file? ? LogTail.read(path, bytes: LogTail::LINES_WINDOW, lines: 3).strip : ""
    end

    sig { params(version_id: String).void }
    def cleanup(version_id)
      FileUtils.rm_f([ progress_path(version_id), log_path(version_id) ])
    end
  end
end
