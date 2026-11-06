# typed: strict
# frozen_string_literal: true

module Playback
  # Publishes every fragment a run here has finished (Publisher) — each under
  # the GOP it really holds, and only if that GOP isn't there already — then
  # tells web (Readiness), so a waiting request is answered the moment it
  # lands (docs/PERF_PROPOSAL.md › P11). From a thread of its own, every few
  # ms, reading only the runs it was last told of; the supervisor's own
  # thread tells it, and takes the last fragments of a run that has exited.
  # A remote run's fragments are published as they're uploaded (NodeLink).
  class RunPublishing
    extend T::Sig

    # Bytes of a run's playlist read for its end: its last line and then some.
    ENDLIST_TAIL = 64

    # A run here as the publishing thread sees it (replaced on every change).
    class Watch < T::Struct
      # Unique to this run: a restart is a new one, published from its start.
      const :key, String
      const :session_id, String
      const :variant, Integer
      const :start_gop, Integer
      const :staging, Pathname
      const :publisher, Publisher
    end

    # A run whose fragments weren't what was planned (Publisher::Mismatch),
    # found on the publishing thread and dealt with on the supervisor's own.
    class Fault < T::Struct
      const :key, String
      const :message, String
    end

    sig { void }
    def initialize
      @watching = T.let([].freeze, T::Array[Watch])
      # The publishing thread's own: the next fragment of each run to publish.
      @published = T.let({}, T::Hash[String, Integer])
      @faults = T.let(Thread::Queue.new, Thread::Queue)
      # Publishing is the publishing thread's, and the supervisor's own for
      # the last fragments of a run that has exited: one at a time.
      @publishing = T.let(Mutex.new, Mutex)
    end

    # The runs to watch from now on.
    sig { params(watches: T::Array[Watch]).void }
    def watch(watches)
      @watching = watches.freeze
    end

    # Everything every watched run has finished since last time.
    sig { void }
    def publish_ready
      watching = @watching
      keys = watching.to_set(&:key)
      @publishing.synchronize do
        @published.select! { |run_key, _| keys.include?(run_key) }
        watching.each { |watch| publish(watch) }
      end
    end

    # The last of what a run that has exited wrote, before it's forgotten.
    sig { params(key: String).void }
    def finish(key)
      watch = @watching.find { |candidate| candidate.key == key }
      @publishing.synchronize { publish(watch, finished: true) } if watch
    end

    # Each fault found since last asked, oldest first.
    sig { params(block: T.proc.params(fault: Fault).void).void }
    def each_fault(&block)
      block.call(@faults.pop(true)) until @faults.empty?
    rescue ThreadError
      nil
    end

    private

    # Everything this run has finished and not yet published, in the order
    # it wrote it. Called holding @publishing.
    sig { params(watch: Watch, finished: T::Boolean).void }
    def publish(watch, finished: false)
      number = @published[watch.key] || watch.start_gop
      return if number.negative?

      latest = T.let(nil, T.nilable(Integer))
      # Whether ffmpeg has ended its playlist, asked before looking for
      # fragments: it ends it only after renaming its last one in, so a scan
      # after seeing the end sees every fragment. Asked after, a fragment
      # renamed in between was missed and the film's last GOP published
      # without it (a 6 s hole, under load).
      finished ||= ended?(watch.staging)
      begin
        while (staged = watch.staging.join("gop-#{number}.m4s")).file?
          # ffmpeg has finished its init by the time it renames a fragment in.
          watch.publisher.init(watch.staging.join("init.mp4")) unless watch.publisher.init?
          latest = watch.publisher.fragment(staged) || latest
          number += 1
        end
        # A run that ran to its end: the film's last GOP has nothing after it
        # to close it. ffmpeg ends its own playlist when it's done, so that's
        # seen here, at once, rather than at the next reap.
        latest = watch.publisher.finish(watch.staging) || latest if finished
      rescue Publisher::Mismatch, Fragment::Unreadable, SystemCallError => e
        # Nothing more of this run is published; the supervisor stops it.
        number = -1
        @faults << Fault.new(key: watch.key, message: e.message)
      end
      @published[watch.key] = number
      Signal.ready(watch.session_id, watch.variant, latest) if latest
    end

    # ffmpeg has written its playlist's end: the run made everything it will.
    # Asked 50 times a second while a GOP is open, of a playlist a line a
    # keyframe long, on the shared cache: only its last line is read.
    sig { params(staging: Pathname).returns(T::Boolean) }
    def ended?(staging)
      held = Publisher::Held.read(staging)
      return false if held.nil? || held.kind != Publisher::Held::OPEN

      tail = File.open(staging.join("run.m3u8"), "rb") do |playlist|
        playlist.seek([ playlist.size - ENDLIST_TAIL, 0 ].max)
        playlist.read
      end
      tail.to_s.include?("#EXT-X-ENDLIST")
    rescue SystemCallError
      false
    end
  end
end
