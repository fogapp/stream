# typed: strict
# frozen_string_literal: true

module Playback
  # Which GOPs make up which HLS segment (PROPOSAL §6.3), fixed before any
  # ffmpeg runs so the playlist is exact and a seek maps straight to a
  # segment. Both the web process (playlists, joining segments) and the
  # transcoder (where to restart ffmpeg) build the same plan from the same
  # rows.
  #
  # Copied video cuts where the source already has keyframes: GOP g starts
  # at keyframe g, and segment N is the GOPs from boundary N to boundary
  # N+1 on the session's target. Converted video puts its own keyframes on
  # a grid of the target, so there every GOP is a segment.
  #
  # The target is the session's own (PlaybackSession#segment_target_ms),
  # fixed when it started: 2 s for new sessions (docs/PERF_PROPOSAL.md ›
  # P10), so the first frame and a seek wait on two seconds of film, not
  # six; sessions from before keep the 6 s they began with.
  class SegmentPlan
    extend T::Sig

    TARGET_MS = 2_000

    class Segment < T::Struct
      const :first_gop, Integer
      const :last_gop, Integer
      const :start_ms, Integer
      const :duration_ms, Integer
    end

    sig { returns(T::Array[Integer]) }
    attr_reader :gop_starts

    sig { returns(T::Array[Segment]) }
    attr_reader :segments

    # A smaller version (Variants) takes the original's keyframes as its
    # own (FfmpegArgs: -force_key_frames source), so its plan is the
    # original's: the same GOPs, the same segments.
    #
    # Every playlist, init and segment request asks for its plan, so a built
    # plan is kept per process (docs/PERF_PROPOSAL.md › P4) and checked
    # against the file's updated_at, which storing a keyframe index moves.
    sig { params(session: PlaybackSession).returns(SegmentPlan) }
    def self.for(session)
      file_id = session.media_file_id.to_s
      copy = session.video_copy?
      target = session.segment_target_ms
      stamp = MediaFile.unscoped.where(id: file_id).pick(:updated_at)
      key = "#{file_id}:#{copy}:#{target}"
      cached = BUILT.fetch(key)
      return cached.last if cached && cached.first == stamp

      plan = build(file_id, copy, target)
      BUILT.store(key, [ stamp, plan ])
      plan
    end

    # Times are the file's own (-copyts), which start where it does: a
    # broadcast recording's at 95,000 s, say. The plan ends at that start
    # plus the duration, and a conversion's grid starts there too —
    # it used to start at 0, and every
    # fragment of such a file was one the plan didn't have.
    sig { params(file_id: String, copy: T::Boolean, target_ms: Integer).returns(SegmentPlan) }
    def self.build(file_id, copy, target_ms)
      seconds, keyframes, start = MediaFile.unscoped.where(id: file_id)
        .pick(:duration_seconds, :keyframes, Arel.sql("probe->'format'->>'start_time'"))
      origin = [ (start.to_f * 1000).round, 0 ].max
      finish = origin + ((seconds || 0) * 1000).round
      copy ? new(gop_starts: Array(keyframes), duration_ms: finish, target_ms: target_ms) : grid(finish - origin, target_ms, origin_ms: origin)
    end
    private_class_method :build

    # A small most-recently-used store, shared by a process's threads.
    class Built
      extend T::Sig

      LIMIT = 128

      sig { void }
      def initialize
        @entries = T.let({}, T::Hash[String, [ T.untyped, SegmentPlan ]])
        @lock = T.let(Mutex.new, Mutex)
      end

      sig { params(key: String).returns(T.nilable([ T.untyped, SegmentPlan ])) }
      def fetch(key)
        @lock.synchronize do
          entry = @entries.delete(key)
          @entries[key] = entry if entry
          entry
        end
      end

      sig { params(key: String, entry: [ T.untyped, SegmentPlan ]).void }
      def store(key, entry)
        @lock.synchronize do
          @entries.delete(key)
          @entries[key] = entry
          @entries.shift while @entries.size > LIMIT
        end
      end
    end

    BUILT = Built.new

    # A container's duration often runs a few milliseconds past the video's
    # last frame (audio ends later); a segment starting in that sliver would
    # never be written, so the last second joins the segment before it.
    TAIL_MS = 1_000

    # Slots every target from where the file starts: the encoder's forced
    # keyframes count time from there (FfmpegArgs.grid_keyframes — its t is
    # the file's or the run's, never the absolute timestamp, and a run
    # always starts on a slot).
    sig { params(duration_ms: Integer, target_ms: Integer, origin_ms: Integer).returns(SegmentPlan) }
    def self.grid(duration_ms, target_ms = TARGET_MS, origin_ms: 0)
      finish = origin_ms + [ duration_ms, 1 ].max
      starts = (origin_ms...finish).step(target_ms).to_a
      starts.pop if starts.size > 1 && finish - T.must(starts.last) < TAIL_MS
      new(gop_starts: starts, duration_ms: finish, one_gop_per_segment: true, target_ms: target_ms)
    end

    # How long segments aim to be: for converted video, the keyframe grid.
    sig { returns(Integer) }
    attr_reader :target_ms

    # duration_ms: where the file ends, on its own timeline (its start plus
    # its duration).
    sig { params(gop_starts: T::Array[Integer], duration_ms: Integer, one_gop_per_segment: T::Boolean, target_ms: Integer).void }
    def initialize(gop_starts:, duration_ms:, one_gop_per_segment: false, target_ms: TARGET_MS)
      @target_ms = target_ms
      @grid = one_gop_per_segment
      @gop_starts = T.let(gop_starts.empty? ? [ 0 ] : gop_starts.sort.uniq, T::Array[Integer])
      @duration_ms = T.let([ duration_ms, T.must(@gop_starts.last) + 1 ].max, Integer)
      boundaries = one_gop_per_segment ? (0...@gop_starts.size).to_a : cumulative_boundaries
      @segments = T.let(boundaries.each_with_index.map do |first, i|
        following = boundaries[i + 1]
        last = (following || @gop_starts.size) - 1
        finish = following ? @gop_starts.fetch(following) : @duration_ms
        start = @gop_starts.fetch(first)
        Segment.new(first_gop: first, last_gop: last, start_ms: start, duration_ms: finish - start)
      end, T::Array[Segment])
    end

    sig { params(gop: Integer).returns(Integer) }
    def gop_start_ms(gop) = @gop_starts.fetch(gop)

    # Where a GOP ends: the next one's keyframe, or the end of the file.
    sig { params(gop: Integer).returns(Integer) }
    def gop_end_ms(gop) = @gop_starts.fetch(gop + 1, @duration_ms)

    sig { returns(Integer) }
    def gop_count = @gop_starts.size

    # Converted video: its keyframes are on the grid rather than the file's own.
    sig { returns(T::Boolean) }
    def grid? = @grid

    # The GOP whose keyframe is at this moment, give or take: slack_ms
    # after it, and before it a couple of milliseconds (the index is
    # rounded) or up to early_ms, when the moment is nearer this keyframe
    # than the one before. nil when no GOP starts there — a keyframe the plan
    # didn't know of, inside a GOP (Publisher).
    sig { params(ms: Integer, slack_ms: Integer, early_ms: Integer).returns(T.nilable(Integer)) }
    def gop_starting_at(ms, slack_ms, early_ms: ROUNDING_MS)
      index = gop_containing(ms) || -1
      return index if !index.negative? && ms - @gop_starts.fetch(index) <= slack_ms

      following = @gop_starts[index + 1]
      return nil if following.nil? || following - ms > early_ms
      return nil if !index.negative? && following - ms >= ms - @gop_starts.fetch(index)

      index + 1
    end

    ROUNDING_MS = 2

    # The GOP whose stretch of the film a moment is in: the last whose
    # keyframe is at or before it. nil before the first.
    sig { params(ms: Integer).returns(T.nilable(Integer)) }
    def gop_containing(ms)
      index = (@gop_starts.bsearch_index { |start| start > ms + ROUNDING_MS } || @gop_starts.size) - 1
      index.negative? ? nil : index
    end

    # The segment playing at a position — where a resume or seek starts.
    # A position is the player's, from the stream's start; the plan's times
    # are the file's own, from its first GOP.
    sig { params(ms: Integer).returns(Integer) }
    def segment_at(ms)
      at = @gop_starts.fetch(0) + ms
      index = @segments.rindex { |segment| segment.start_ms <= at }
      index || 0
    end

    sig { returns(Integer) }
    def target_duration_seconds = (@segments.map(&:duration_ms).max.to_i / 1000.0).ceil

    private

    # Cut at the first keyframe at or past each multiple of the target
    # (spikes.md › B). Keyframes further apart than the target just make
    # longer segments.
    sig { returns(T::Array[Integer]) }
    def cumulative_boundaries
      first = @gop_starts.fetch(0)
      boundaries = [ 0 ]
      n = 1
      @gop_starts.each_with_index do |time, index|
        next if index.zero? || time < first + (n * @target_ms)

        boundaries << index
        n += 1 while time >= first + (n * @target_ms)
      end
      boundaries
    end
  end
end
