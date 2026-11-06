# typed: false
# frozen_string_literal: true

# Media specs run the real ffprobe against the fixture corpus
# (spec/fixtures/media). CI installs jellyfin-ffmpeg, so a missing ffprobe
# there is a failure; on a laptop without ffmpeg the examples are skipped
# with a note rather than turning the suite red.
module MediaHelpers
  FIXTURES = File.expand_path("../fixtures/media", __dir__)

  def media_fixture(name) = File.join(FIXTURES, name)

  # bin/transcoder's publishing thread, for a spec with a supervisor: what a
  # run finishes is published from its own directory (Playback::Publisher)
  # and announced — here, to nobody. Kill what it returns when done.
  def publish_runs
    allow(Playback::Signal).to receive(:ready)
    Thread.new do
      loop do
        yield.publish_ready
        sleep 0.02
      end
    end
  end

  def require_ffprobe!
    return if ToolRunner.available?("ffprobe")
    raise "ffprobe is not on PATH" if ENV["CI"]

    skip "ffprobe not on PATH — `brew install ffmpeg`, or run specs in the dev image"
  end

  # A throwaway library root holding copies of the named fixtures at the
  # given relative paths: { "Movies/Heat (1995)/Heat.mkv" => "h264_aac.mp4" }.
  def build_root(files = {})
    root = Dir.mktmpdir("stream-root")
    files.each do |relative, fixture|
      target = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(media_fixture(fixture), target)
    end
    @built_roots = (@built_roots || []) << root
    root
  end

  # Every entry under a root with its size and mtime — what "never write into
  # a library root" (CLAUDE.md, media invariant 1) is checked against.
  def root_snapshot(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |relative| File.basename(relative) == "." }.sort.to_h do |relative|
      stat = File.lstat(File.join(root, relative))
      [ relative, [ stat.ftype, stat.size, stat.mtime.to_r ] ]
    end
  end

  # The roots' contents are fixed from here: what the spec put there is the
  # library; anything that changes afterwards is Stream's doing.
  def create_library(household:, roots:, kind: "movies", name: "Movies #{SecureRandom.hex(3)}")
    Library.create!(household: household, name: name, kind: kind, roots: Array(roots)).tap do
      settle_library_roots!(*Array(roots))
    end
  end

  # For a spec that changes a root itself after making the library (adding
  # a file for a rescan to find): take what's there now as the baseline.
  def settle_library_roots!(*roots)
    roots = Array(@root_snapshots&.keys) if roots.empty?
    roots.each { |root| (@root_snapshots ||= {})[root.to_s] = root_snapshot(root.to_s) if File.directory?(root.to_s) }
  end
end

RSpec.configure do |config|
  config.include MediaHelpers
  config.after do
    Array(@built_roots).each { |root| FileUtils.rm_rf(root) }
  end

  # After hooks run last-declared first, so this check sees the roots before
  # the cleanup above removes them.
  # Media invariant 1: whatever the example ran, the library roots it built
  # hold exactly what they held when it built them. An example that plays
  # Sonarr (adding, moving or deleting files itself) says so with
  # :changes_library_root.
  config.after do |example|
    next if example.metadata[:changes_library_root] || example.exception

    Array(@root_snapshots).each do |root, before|
      next unless File.directory?(root)

      after = root_snapshot(root)
      next if after == before

      changed = (before.keys | after.keys).reject { |relative| before[relative] == after[relative] }
      raise "Wrote into a library root (#{root}): #{changed.first(5).join(', ')}"
    end
  end
end
