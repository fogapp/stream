# typed: strict
# frozen_string_literal: true

module Playback
  # Where a session's fragments live on the shared cache volume (PROPOSAL
  # §3.2): the transcoder writes them, web serves them.
  module Cache
    extend T::Sig

    sig { returns(Pathname) }
    def self.root
      Pathname.new(ENV.fetch("STREAM_CACHE_DIR") { Rails.root.join("tmp", "cache", "stream").to_s }).join("sessions")
    end

    # A session's own stream in its directory; a smaller version of it
    # (Variants) in v<n> inside.
    sig { params(session_id: String, variant: Integer).returns(Pathname) }
    def self.directory(session_id, variant = 0)
      variant.zero? ? root.join(session_id) : root.join(session_id, "v#{variant}")
    end

    UNKNOWN_FREE = T.let(1 << 60, Integer)
    FREE_CHECKED_FOR = 30.0

    # Free space on the cache's disk, in bytes, looked at no more than every
    # half minute unless it matters that it's now (df, argv only: Ruby has
    # no statvfs). Unknown is plenty — not knowing is no reason to refuse
    # anyone.
    sig { params(fresh: T::Boolean).returns(Integer) }
    def self.free_bytes(fresh: false)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      cached = FREE.value
      return cached.last if !fresh && cached && now - cached.first < FREE_CHECKED_FOR

      FileUtils.mkdir_p(root)
      line = IO.popen([ "df", "-Pk", root.to_s ], err: File::NULL, &:read).to_s.lines.last.to_s
      kilobytes = T.let(Integer(line.split[3].to_s, exception: false), T.nilable(Integer))
      free = kilobytes ? kilobytes * 1024 : UNKNOWN_FREE
      FREE.value = [ now, free ]
      free
    rescue SystemCallError
      UNKNOWN_FREE
    end

    # The last look: when, and what it found.
    FREE = T.let(Struct.new(:value).new(nil), T.untyped)

    # Where one run's ffmpeg (or its worker's uploads) puts what it makes,
    # before each fragment is published under the GOP it really holds
    # (Publisher).
    sig { params(session_id: String, run: String, variant: Integer).returns(Pathname) }
    def self.staging(session_id, run, variant = 0) = directory(session_id, variant).join("run-#{run}")

    sig { params(session_id: String, gop: Integer, variant: Integer).returns(Pathname) }
    def self.gop(session_id, gop, variant = 0) = directory(session_id, variant).join("gop-#{gop}.m4s")

    sig { params(session_id: String, segment: Integer, variant: Integer).returns(Pathname) }
    def self.segment(session_id, segment, variant = 0) = directory(session_id, variant).join("seg-#{segment}.m4s")

    sig { params(session_id: String, variant: Integer).returns(Pathname) }
    def self.init(session_id, variant = 0) = directory(session_id, variant).join("init.mp4")

    # A fragment is here only once its run finished it (-hls_flags
    # temp_file) and it was published under the GOP it holds (Publisher) —
    # a rename each time — so existence means complete, and it's never
    # replaced.
    sig { params(session_id: String, gop: Integer, variant: Integer).returns(T::Boolean) }
    def self.gop_ready?(session_id, gop, variant = 0) = gop(session_id, gop, variant).file?

    # The init segment is published once, whole, when its run's first
    # fragment is (Publisher): ffmpeg writes its own in place, and has
    # finished it by then. A fragment beside it is still what says the
    # stream has started.
    sig { params(session_id: String, variant: Integer).returns(T::Boolean) }
    def self.init_ready?(session_id, variant = 0)
      path = init(session_id, variant)
      return false unless path.file? && path.size.positive?

      Dir.each_child(directory(session_id, variant)).any? { |name| name.start_with?("gop-") && name.end_with?(".m4s") }
    rescue SystemCallError
      false
    end
  end
end
