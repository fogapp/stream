# typed: strict
# frozen_string_literal: true

# Thin, careful wrapper around external tools (pg_dump, tar, ffmpeg, ffprobe, fpcalc).
# Ported from feed:app/services/media/tool_runner.rb.
#
# Everything here is about not trusting the subprocess: explicit argv (never
# a shell string), a hard timeout, bounded output capture, and the child
# killed by process group so a spawned grandchild dies with its parent.
module ToolRunner
  extend T::Sig

  class Error < StandardError; end
  class Timeout < Error; end

  DEFAULT_TIMEOUT = T.let(900, Integer)
  MAX_OUTPUT_BYTES = T.let(256 * 1024, Integer)
  # How often a streaming tool's hold is looked at (and a held one woken).
  HOLD_POLL = T.let(10, Integer)
  # Longer than any evening's watching: a hold this long without a break is
  # one that can't be lifted, and the read gives up as a Timeout (its job's
  # retry, its AnalysisRun's last_error) rather than keep a worker thread
  # forever. A hold that was never lifted kept both heavy threads from
  # 15:30 on 2026-10-21 until a deploy.
  MAX_HELD = T.let(6 * 3600, Integer)

  # Whether the tool should stand still right now: someone's watching, and a
  # whole-file read on the heavy queue would starve their playback of the
  # share (HoldHeavyWhileWatchingJob).
  Hold = T.type_alias { T.proc.returns(T::Boolean) }

  class Result < T::Struct
    extend T::Sig

    const :status, Integer
    const :stdout, String
    const :stderr, String

    sig { returns(T::Boolean) }
    def success? = status.zero?
  end

  sig { params(argv: T::Array[String], timeout: Integer, env: T::Hash[String, String]).returns(Result) }
  def self.run(argv, timeout: DEFAULT_TIMEOUT, env: {})
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe

    # pgroup: true so the whole tree can be signalled. env entries overlay the
    # parent environment (how pg_dump gets PGPASSWORD without it appearing in
    # argv).
    pid = T.unsafe(Process).spawn(env, *exec_argv(argv), out: out_w, err: err_w, pgroup: true)
    out_w.close
    err_w.close

    readers = [ reader_thread(out_r), reader_thread(err_r) ]
    waiter = Thread.new { Process.waitpid2(pid) }

    if waiter.join(timeout).nil?
      kill_group(pid)
      readers.each { |thread| thread.join(5) }
      if waiter.join(5).nil?
        # A child wedged in uninterruptible IO (a hung NAS mount) can outlive
        # even SIGKILL's delivery window. Hand the reaping to a detached
        # watcher rather than leaking the waiter thread and a zombie.
        waiter.kill
        Process.detach(pid)
      end
      raise Timeout, "#{argv.first} exceeded #{timeout}s"
    end

    status = T.cast(waiter.value, [ Integer, Process::Status ])[1]
    stdout = readers.fetch(0).value.to_s
    stderr = readers.fetch(1).value.to_s

    Result.new(status: status.exitstatus || -1, stdout: stdout, stderr: stderr)
  ensure
    [ out_r, err_r, out_w, err_w ].each { |io| io.close unless io.nil? || io.closed? }
  end

  # For a tool whose output is the whole answer and can run to megabytes (a
  # packet list): each stdout line is yielded as it arrives instead of
  # captured, and the clock is how long the tool has gone quiet, not how long
  # it has run — a whole-file read takes as long as the share takes, and only
  # a stall is a failure. The returned Result's stdout is empty; its stderr
  # is the tool's last 256 KB, where ffmpeg's summaries and errors are.
  #
  # With a hold, the tool is stopped (SIGSTOP) for as long as the hold says
  # so and continued after, and the quiet clock stands still with it.
  sig do
    params(argv: T::Array[String], idle_timeout: Integer, hold: T.nilable(Hold), blk: T.proc.params(line: String).void)
      .returns(Result)
  end
  def self.each_line(argv, idle_timeout:, hold: nil, &blk)
    stream(argv, Watch.new(argv.fetch(0), timeout: idle_timeout, hold: hold, advancing: false), &blk)
  end

  # ffmpeg reading a whole file, judged by whether it's getting anywhere
  # rather than by a budget per gigabyte: a busy share reads at single-digit
  # MB/s, and a budget timed out healthy reads of every size on it (Glass,
  # 2026-10-10). The argv carries `-progress pipe:1`, whose report comes
  # every half second whether or not the read moves — so the clock is how
  # long out_time has stood still, and a read that never starts counts too.
  sig { params(argv: T::Array[String], stall_timeout: Integer, hold: T.nilable(Hold)).returns(Result) }
  def self.run_advancing(argv, stall_timeout:, hold: nil)
    stream(argv, Watch.new(argv.fetch(0), timeout: stall_timeout, hold: hold, advancing: true)) { nil }
  end

  # One streaming run's clocks: how long the tool has made no progress (a
  # line, or in advancing mode a greater out_time), not counting the time
  # it spent held.
  class Watch
    extend T::Sig

    sig { params(tool: String, timeout: Integer, hold: T.nilable(Hold), advancing: T::Boolean).void }
    def initialize(tool, timeout:, hold:, advancing:)
      @tool = tool
      @timeout = timeout
      @hold = hold
      @advancing = advancing
      @pid = T.let(nil, T.nilable(Integer))
      @held_since = T.let(nil, T.nilable(Float))
      @held_for = T.let(0.0, Float)
      @furthest = T.let(-1, Integer)
      @progress_at = T.let(working_now, Float)
    end

    sig { returns(Integer) }
    attr_reader :timeout

    sig { params(pid: Integer).void }
    def watch(pid)
      @pid = pid
    end

    # Stops or continues the tool as the hold says, and answers how long to
    # wait for its next line.
    sig { returns(Integer) }
    def poll
      wanted = @hold ? holding? : false
      if wanted && @held_since.nil?
        signal("-STOP")
        @held_since = now
        Rails.logger.info("[tool_runner] #{@tool} held while someone watches")
      elsif !wanted && @held_since
        signal("-CONT")
        @held_for += now - @held_since
        @held_since = nil
        Rails.logger.info("[tool_runner] #{@tool} resumed after #{@held_for.round}s held in all")
      end
      return HOLD_POLL if @held_since

      [ HOLD_POLL, (@timeout - (working_now - @progress_at)).ceil ].min.clamp(1, HOLD_POLL)
    end

    sig { params(line: String).void }
    def saw(line)
      if @advancing
        micros = line[/\Aout_time_us=(\d+)/, 1]&.to_i
        return unless micros && micros > @furthest

        @furthest = micros
      end
      @progress_at = working_now
    end

    # Raised the moment the tool has made no progress for the timeout, or
    # has been held without a break for MAX_HELD.
    sig { void }
    def check!
      if (since = @held_since)
        raise Timeout, "#{@tool} held for #{(now - since).round}s without a break" if now - since > MAX_HELD

        return
      end
      return if working_now - @progress_at <= @timeout

      raise Timeout, "#{@tool} #{@advancing ? 'stopped advancing' : 'went quiet'} for #{@timeout}s"
    end

    # A held tool can't exit: let it go before waiting for it to.
    sig { void }
    def release
      return if @held_since.nil?

      signal("-CONT")
      @held_since = nil
    end

    private

    sig { returns(Float) }
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f

    sig { returns(Float) }
    def working_now
      since = @held_since
      now - @held_for - (since ? now - since : 0.0)
    end

    # A hold that can't be read (the queue database away for a moment) is
    # left as it was, not the end of an hours-long read.
    sig { returns(T::Boolean) }
    def holding?
      T.must(@hold).call
    rescue StandardError => e
      Rails.logger.warn("[tool_runner] hold unreadable (#{e.class}: #{e.message}); #{@tool} left #{@held_since ? 'held' : 'running'}")
      !@held_since.nil?
    end

    sig { params(signal: String).void }
    def signal(signal)
      pid = @pid
      return if pid.nil?

      Process.kill(signal, Process.getpgid(pid))
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  sig { params(argv: T::Array[String], watch: Watch, blk: T.proc.params(line: String).void).returns(Result) }
  def self.stream(argv, watch, &blk)
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe

    pid = T.unsafe(Process).spawn(*exec_argv(argv), out: out_w, err: err_w, pgroup: true)
    out_w.close
    err_w.close
    watch.watch(pid)

    errors = reader_thread(err_r, keep: :tail)
    pending = +""
    begin
      read_lines(out_r, pending, watch, &blk)
    rescue StandardError
      # Gone quiet, or the block gave up on it (a stall).
      kill_group(pid)
      Process.detach(pid)
      raise
    end
    watch.release

    # Closing stdout isn't exiting: give it the same grace before calling it
    # stuck.
    waiter = Thread.new { Process.waitpid2(pid) }
    if waiter.join(watch.timeout).nil?
      kill_group(pid)
      waiter.kill
      Process.detach(pid)
      raise Timeout, "#{argv.first} went quiet for #{watch.timeout}s"
    end

    status = T.cast(waiter.value, [ Integer, Process::Status ])[1]
    Result.new(status: status.exitstatus || -1, stdout: "", stderr: errors.value.to_s)
  ensure
    [ out_r, err_r, out_w, err_w ].each { |io| io.close unless io.nil? || io.closed? }
  end
  private_class_method :stream

  sig { params(out_r: IO, pending: String, watch: Watch, blk: T.proc.params(line: String).void).void }
  def self.read_lines(out_r, pending, watch, &blk)
    loop do
      if out_r.wait_readable(watch.poll).nil?
        watch.check!
        next
      end

      # Readable now, so this returns what's there without waiting.
      begin
        pending << out_r.readpartial(65_536)
      rescue EOFError
        break
      end
      while (newline = pending.index("\n"))
        line = T.must(pending.slice!(0, newline + 1))
        watch.saw(line)
        blk.call(line)
      end
      watch.check!
    end
    blk.call(pending) unless pending.empty?
  end
  private_class_method :read_lines

  # Process.spawn hands a lone string to /bin/sh; spelling the program as
  # [path, argv0] means argv is exec'd directly whatever its length.
  sig { params(argv: T::Array[String]).returns(T::Array[T.any(String, T::Array[String])]) }
  def self.exec_argv(argv)
    program = argv.first
    raise ArgumentError, "an empty argv runs nothing" if program.nil?

    [ [ program, program ], *argv.drop(1) ]
  end

  # Reads until EOF but stops accumulating past the cap — a tool that goes
  # berserk on stderr shouldn't be able to exhaust memory. Keeps the first
  # 256 KB, or with keep: :tail the last: where a long run's summary is.
  sig { params(io: IO, keep: Symbol).returns(Thread) }
  def self.reader_thread(io, keep: :head)
    Thread.new do
      buffer = +""
      begin
        while (chunk = io.read(65_536))
          if keep == :tail
            buffer << chunk
            buffer = T.must(buffer.byteslice(buffer.bytesize - MAX_OUTPUT_BYTES, MAX_OUTPUT_BYTES)) if buffer.bytesize > MAX_OUTPUT_BYTES
          elsif buffer.bytesize < MAX_OUTPUT_BYTES
            buffer << chunk
          end
        end
      rescue IOError
        nil
      end
      buffer
    end
  end
  private_class_method :reader_thread

  sig { params(pid: Integer).void }
  def self.kill_group(pid)
    group = Process.getpgid(pid)
    # A held (stopped) tool takes no signal but KILL until it's continued.
    Process.kill("-CONT", group)
    Process.kill("-TERM", group)
    # Poll through the grace period instead of a flat sleep(2): most tools
    # die instantly, and this blocks a worker thread. getpgid raises ESRCH
    # once the group is gone, short-circuiting into the rescue.
    20.times do
      sleep 0.1
      Process.getpgid(pid)
    end
    Process.kill("-KILL", group)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
  private_class_method :kill_group

  # Positive probes memoized for the process lifetime: a tool that answered
  # once is installed. Missing tools keep probing — the failed spawn is
  # cheap, and it lets a newly-installed binary be noticed without a restart.
  @versions = T.let({}, T::Hash[String, String])

  VERSION_FLAGS = T.let(%w[--version -version].freeze, T::Array[String])

  sig { params(tool: String).returns(T.nilable(String)) }
  def self.version(tool)
    memoized = @versions[tool]
    return memoized if memoized

    VERSION_FLAGS.each do |flag|
      result = run([ tool, flag ], timeout: 20)
      next unless result.success?

      line = result.stdout.strip.lines.first&.strip
      return @versions[tool] = line if line.present?
    end
    nil
  rescue StandardError
    nil
  end

  sig { params(tool: String).returns(T::Boolean) }
  def self.available?(tool) = !version(tool).nil?
end
