# typed: strict
# frozen_string_literal: true

module Playback
  # Starts, watches and stops one ffmpeg run, here or on a remote
  # transcoder, so the supervisor and the optimizer don't care which. Here
  # it's a child process; there it's a TranscodeRun row the node's worker
  # picks up on its next poll.
  module Runner
    extend T::Sig

    # {server} is the Stream address the worker was started with; {out} is
    # the worker's scratch directory for this run.
    SERVER = "{server}"
    OUT = "{out}"

    class Exit < T::Struct
      extend T::Sig

      # nil when it was killed, or never reported one.
      const :status, T.nilable(Integer)
      # The signal that killed it, when one did.
      const :signal, T.nilable(Integer), default: nil
      const :message, T.nilable(String), default: nil
      # The node stopped polling: whatever it was doing has to happen
      # somewhere else.
      const :offline, T::Boolean, default: false
      # What went wrong, when an exit code can't say: a remote run's row
      # knows what was refused or lost, and a node can't report a signal.
      const :failure, T.nilable(TranscodeRun::Failure), default: nil

      sig { returns(T::Boolean) }
      def success? = status&.zero? || false
    end

    # A run under way, wherever it is.
    class Handle
      extend T::Sig
      extend T::Helpers

      abstract!

      # nil while it's still going.
      sig { abstract.returns(T.nilable(Exit)) }
      def poll; end

      sig { abstract.params(wait: T::Boolean).void }
      def kill(wait: false); end

      # Still going, as far as a request is concerned. Doesn't reap: a run
      # that died is left for the next poll to say why.
      sig { abstract.returns(T::Boolean) }
      def alive?; end

      sig { abstract.returns(T::Boolean) }
      def remote?; end

      # Only a child process of this one can be stopped and let go again.
      sig { overridable.void }
      def pause; end

      sig { overridable.void }
      def resume; end

      # How far its worker says it has got; a run here says so in its files.
      sig { overridable.returns(T.nilable(Float)) }
      def progress_seconds = nil

      sig { overridable.returns(T.nilable(Integer)) }
      def pid = nil

      sig { overridable.returns(T.nilable(String)) }
      def run_id = nil

      sig { overridable.returns(T.nilable(String)) }
      def node_id = nil
    end

    # A child process of this one, in a process group of its own.
    class LocalHandle < Handle
      sig { params(pid: Integer).void }
      def initialize(pid:)
        super()
        @pid = pid
      end

      sig { override.returns(Integer) }
      attr_reader :pid

      sig { override.returns(T.nilable(Exit)) }
      def poll
        reaped = Process.wait2(@pid, Process::WNOHANG)
        return nil if reaped.nil?

        Exit.new(status: reaped.last.exitstatus, signal: reaped.last.termsig)
      rescue Errno::ECHILD
        Exit.new(status: nil)
      end

      # SIGKILL, never TERM: ffmpeg would take a TERM as the end of its input
      # and rename its half-written GOP into place, where web would serve it
      # as whole. The kill is instant; the exited child is reaped on a thread
      # (Process.detach) unless the caller waits, so a seek's restart never
      # blocks on it (docs/PERF_PROPOSAL.md › P15).
      sig { override.params(wait: T::Boolean).void }
      def kill(wait: false)
        Process.kill("-KILL", @pid)
        reaper = Process.detach(@pid)
        reaper.join if wait
      rescue Errno::ESRCH, Errno::ECHILD, Errno::EPERM
        nil
      end

      sig { override.returns(T::Boolean) }
      def alive?
        Process.kill(0, @pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      sig { override.returns(T::Boolean) }
      def remote? = false

      sig { override.void }
      def pause = group_signal("STOP")

      sig { override.void }
      def resume = group_signal("CONT")

      private

      sig { params(name: String).void }
      def group_signal(name)
        Process.kill("-#{name}", @pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    # A TranscodeRun row its node's worker picks up on its next poll.
    class RemoteHandle < Handle
      sig { params(run_id: String, node_id: T.nilable(String)).void }
      def initialize(run_id:, node_id: nil)
        super()
        @run_id = run_id
        @node_id = node_id
      end

      sig { override.returns(String) }
      attr_reader :run_id

      sig { override.returns(T.nilable(String)) }
      attr_reader :node_id

      # A row that has gone says nothing: nobody is waiting to hear. An exit
      # with no code and nothing on the row is a run killed on its node,
      # since one stopped from here has left the list by the time it exits.
      sig { override.returns(T.nilable(Exit)) }
      def poll
        run = TranscodeRun.includes(:transcode_node).find_by(id: @run_id)
        return Exit.new(status: nil) if run.nil?

        if run.state_enum == TranscodeRun::State::Exited
          failure = run.failure_enum || (run.exit_status.nil? ? TranscodeRun::Failure::Crashed : nil)
          return Exit.new(status: run.exit_status, message: run.log_tail, failure: failure)
        end

        node = run.transcode_node
        return nil if node&.online?

        run.exited!(nil, "#{node&.name || 'The remote transcoder'} went offline")
        Exit.new(status: nil, message: run.log_tail, offline: true)
      end

      # Stopped by its worker on its next poll. Never handed out: nothing to kill.
      sig { override.params(wait: T::Boolean).void }
      def kill(wait: false)
        TranscodeRun.where(id: @run_id, state: TranscodeRun::State::Running.serialize)
          .update_all(state: TranscodeRun::State::Stopping.serialize, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        TranscodeRun.where(id: @run_id, state: TranscodeRun::State::Pending.serialize)
          .update_all(state: TranscodeRun::State::Exited.serialize, finished_at: Time.current, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end

      sig { override.returns(T::Boolean) }
      def alive? = TranscodeRun.remote.live.exists?(id: @run_id) && TranscodeNode.online.exists?(id: @node_id)

      sig { override.returns(T::Boolean) }
      def remote? = true

      sig { override.returns(Float) }
      def progress_seconds = TranscodeRun.where(id: @run_id).pick(:progress_seconds).to_f
    end

    # redact: what ffmpeg says passes through it on its way to the log — a
    # live stream's address is a secret (LiveStream#redact), and ffmpeg
    # quotes it in every complaint.
    sig do
      params(argv: T::Array[String], log: Pathname, redact: T.nilable(T.proc.params(text: String).returns(String))).returns(LocalHandle)
    end
    def self.spawn_local(argv, log:, redact: nil)
      Lucid.increment("transcoder.runs", tags: { placement: "local" })
      if redact.nil?
        return LocalHandle.new(pid: T.unsafe(Process).spawn(*ToolRunner.exec_argv(argv), out: File::NULL, err: [ log.to_s, "a" ], pgroup: true))
      end

      reader, writer = IO.pipe
      pid = T.unsafe(Process).spawn(*ToolRunner.exec_argv(argv), out: File::NULL, err: writer, pgroup: true)
      writer.close
      Thread.new do
        File.open(log, "a") do |file|
          reader.each_line do |line|
            file.write(redact.call(line))
            file.flush
          end
        end
      rescue IOError, SystemCallError
        nil
      ensure
        reader.close
      end
      LocalHandle.new(pid: pid)
    end

    # A run for a node; the argv is built once its id (and so its source
    # URL) exists.
    sig do
      params(node: TranscodeNode, session: T.nilable(PlaybackSession), version: T.nilable(OptimizedVersion),
        argv: T.proc.params(source: FfmpegArgs::Input).returns(T::Array[String])).returns(RemoteHandle)
    end
    def self.start_remote(node, session: nil, version: nil, &argv)
      run = TranscodeRun.create!(transcode_node: node, playback_session: session, optimized_version: version)
      Lucid.increment("transcoder.runs", tags: { placement: "remote" })
      # A fog transcoder's machine reaches only Stream's /fog/compute/ through
      # fog's data route; a worker reads /media/n directly.
      prefix = node.fog? ? "fog/compute/runs" : "media/n"
      source = FfmpegArgs::Input.remote("#{SERVER}/#{prefix}/#{RunToken.issue(run)}/source")
      run.update!(argv: argv.call(source))
      RemoteHandle.new(run_id: run.id, node_id: node.id)
    end

    sig { params(handle: Handle).returns(T.nilable(Exit)) }
    def self.poll(handle) = handle.poll

    sig { params(handle: Handle, wait: T::Boolean).void }
    def self.kill(handle, wait: false) = handle.kill(wait: wait)
  end
end
