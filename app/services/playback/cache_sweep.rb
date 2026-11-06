# typed: strict
# frozen_string_literal: true

module Playback
  # Keeps the cache of sessions' fragments inside its budget, and its disk
  # from filling. Called from the sweep's own thread (bin/transcoder), so a
  # seek never waits behind a walk of it, and from the supervisor's when a
  # run finds the disk nearly full. It reads only the snapshots it is
  # handed, which the supervisor publishes.
  class CacheSweep
    extend T::Sig

    # A session's fragments are deleted this long after it was last seen.
    KEEP = T.let(10.minutes, ActiveSupport::Duration)
    CACHE_BUDGET = T.let(20.gigabytes, Integer)
    # Free space the cache's disk keeps: a run that would take it below is
    # refused, rather than every run failing when the disk fills.
    FREE_FLOOR = T.let(3.gigabytes, Integer)
    # A sweep this recent found all there was to find: a run that wants
    # room doesn't walk the cache again for it.
    FRESH_FOR = 5.0

    sig { params(running: T.proc.returns(T::Set[String]), asked: T.proc.returns(T::Hash[String, Integer])).void }
    def initialize(running:, asked:)
      @running = running
      @asked = asked
      @walking = T.let(Mutex.new, Mutex)
      @swept_at = T.let(nil, T.nilable(Float))
    end

    # Fragments of sessions long over, then the oldest first until the cache
    # fits its budget.
    sig { void }
    def call
      @walking.synchronize do
        walk
        @swept_at = monotonic
      end
    end

    # Room on the cache's disk for another run, or why there isn't: swept at
    # once, and a disk still too full refuses the run with a reason (the
    # player falls back, and the admin sees it in Activity).
    sig { void }
    def ensure_room!
      return if Cache.free_bytes >= FREE_FLOOR

      # A sweep going now is making the room, and the floor is margin enough
      # to start on: refusing would mark this rung failed for the file, for a
      # disk that's minutes from fine (Playback::Fallback).
      return if @walking.locked?

      call unless fresh?
      free = Cache.free_bytes(fresh: true)
      return if free >= FREE_FLOOR

      raise "the transcoder's cache disk is full (#{free / 1.megabyte} MB free)"
    end

    private

    sig { void }
    def walk
      root = Cache.root
      return unless root.directory?

      running = @running.call
      forget_long_over(root, running)
      sizes = root.children.select(&:directory?).map { |dir| [ dir, size_of(dir) ] }
      total = sizes.sum(&:last)
      sizes.sort_by { |dir, _| dir.mtime }.each do |dir, size|
        break if total <= CACHE_BUDGET
        next if running.include?(dir.basename.to_s)

        FileUtils.rm_rf(dir)
        total -= size
      end
      return if total <= CACHE_BUDGET

      trim_running(sizes.map(&:first).select { |dir| running.include?(dir.basename.to_s) }, total)
    end

    sig { params(root: Pathname, running: T::Set[String]).void }
    def forget_long_over(root, running)
      directories = root.children.select(&:directory?)
      live = PlaybackSession.unscoped.where(id: directories.map { |dir| dir.basename.to_s })
        .where(state: PlaybackSession::State::Active.serialize).where(last_seen_at: KEEP.ago..).pluck(:id).to_set
      directories.each do |dir|
        next if live.include?(dir.basename.to_s) || running.include?(dir.basename.to_s)
        next if dir.mtime > KEEP.ago

        FileUtils.rm_rf(dir)
      end
    end

    # Still over with only running sessions left: the oldest of what each
    # made, until it fits. Never what's ahead of where its player last had
    # to ask, which a paused viewer is still to reach; what's behind comes
    # back, made again, if they seek to it (Supervisor::Run#reaches?).
    sig { params(directories: T::Array[Pathname], total: Integer).void }
    def trim_running(directories, total)
      asked = @asked.call
      made = directories.flat_map { |dir| dir.glob("**/{gop,seg}-*.m4s") }.reject { |path| spared?(path, asked) }
      made.sort_by(&:mtime).each do |path|
        break if total <= CACHE_BUDGET

        total -= path.size
        FileUtils.rm_f(path)
      end
    end

    sig { params(path: Pathname, asked: T::Hash[String, Integer]).returns(T::Boolean) }
    def spared?(path, asked)
      return true if path.dirname.basename.to_s.start_with?("run-") || path.mtime > KEEP.ago

      gop = path.basename.to_s[/\Agop-(\d+)/, 1]
      wanted = asked[path.dirname.to_s]
      !gop.nil? && !wanted.nil? && gop.to_i >= wanted
    end

    sig { params(directory: Pathname).returns(Integer) }
    def size_of(directory)
      directory.glob("**/*").sum { |path| path.file? ? path.size : 0 }
    end

    sig { returns(T::Boolean) }
    def fresh?
      swept = @swept_at
      !swept.nil? && monotonic - swept < FRESH_FOR
    end

    sig { returns(Float) }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
  end
end
