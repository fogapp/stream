# typed: strict
# frozen_string_literal: true

module Playback
  # How fast a library root delivers bytes to the transcoder
  # (docs/APPLETV_STALLS.md › R1), learned from the runs themselves: while a
  # run is inside its initial burst ffmpeg reads as fast as the share lets
  # it, so the film it has made, times the file's bitrate, over the time it
  # took is the share's speed. No extra reads, nothing to schedule.
  #
  # A NAS across a router hop (47 ms per NFS read) can give 6 MB/s for
  # everyone at once where a share on the same LAN gives 100. Kept in the Rails
  # cache (Solid Cache in production, so web, worker and transcoder share
  # it), averaged so one busy evening doesn't define the share for good.
  module ShareSpeed
    extend T::Sig

    # How long a reading stands without another.
    KEEP = T.let(7.days, ActiveSupport::Duration)
    # The weight a new sample carries against what was known.
    WEIGHT = 0.3
    # Read from the cache at most this often per process: a lookup is a
    # query, and a launch shouldn't wait on one more than it must.
    MEMO_FOR = 60.0

    MEMO = T.let({}, T::Hash[String, [ T.nilable(Float), Float ]])
    LOCK = Mutex.new

    # Bytes a second, or nil when no run from this root has been measured.
    sig { params(root: String).returns(T.nilable(Float)) }
    def self.read(root)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      LOCK.synchronize do
        memo = MEMO[root]
        return memo.first if memo && now - memo.last < MEMO_FOR
      end
      value = Rails.cache.read(cache_key(root))
      speed = value.is_a?(Numeric) && value.positive? ? value.to_f : nil
      LOCK.synchronize { MEMO[root] = [ speed, now ] }
      speed
    end

    # A run's measurement: folded into what was known.
    sig { params(root: String, bytes_per_second: Float).void }
    def self.record(root, bytes_per_second)
      return unless bytes_per_second.finite? && bytes_per_second.positive?

      known = Rails.cache.read(cache_key(root))
      speed = known.is_a?(Numeric) && known.positive? ? (known.to_f * (1 - WEIGHT)) + (bytes_per_second * WEIGHT) : bytes_per_second
      Rails.cache.write(cache_key(root), speed, expires_in: KEEP)
      LOCK.synchronize { MEMO[root] = [ speed, Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f ] }
    end

    # What a run on a remote transcoder shows (ShareMeasure): the
    # share gave at least this, though the encoder or the network may be
    # what held it there. So it can raise a reading but never lower one, and
    # either way the reading stays: otherwise a share only remote runs
    # convert from is forgotten after KEEP.
    sig { params(root: String, bytes_per_second: Float).void }
    def self.floor(root, bytes_per_second)
      return unless bytes_per_second.finite? && bytes_per_second.positive?

      known = Rails.cache.read(cache_key(root))
      speed = known.is_a?(Numeric) && known.positive? ? [ known.to_f, bytes_per_second ].max : bytes_per_second
      Rails.cache.write(cache_key(root), speed, expires_in: KEEP)
      LOCK.synchronize { MEMO[root] = [ speed, Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f ] }
    end

    sig { void }
    def self.forget!
      LOCK.synchronize { MEMO.clear }
    end

    sig { params(root: String).returns(String) }
    def self.cache_key(root) = "playback/share_speed/v1/#{root}"
  end
end
