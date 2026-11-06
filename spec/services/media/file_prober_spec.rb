# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Media::FileProber do
  before { require_ffprobe! }

  let(:household) { Household.create!(name: "Probe") }

  def discovered(library, path)
    stat = File.stat(path)
    MediaFile.create!(household: household, library: library, path: path, size: stat.size, mtime: stat.mtime,
      state: "discovered")
  end

  it "fingerprints, probes, stores the streams and records the run" do
    root = build_root("Heat.mkv" => "h264_aac_ac3_subs.mkv")
    file = discovered(create_library(household: household, roots: root), File.join(root, "Heat.mkv"))

    expect(described_class.new(file).call).to eq(described_class::Outcome::Probed)

    file.reload
    expect(file).to have_attributes(state: "probed", fingerprint: match(/\A\h{16}\z/), last_error: nil)
    expect(file.duration_seconds).to be_within(0.2).of(2.0)
    expect(file.media_streams.map(&:kind)).to eq(%w[video audio audio subtitle subtitle])
    expect(file.analysis_runs.sole).to have_attributes(step: "probe", status: "succeeded", tool_version: be_present)
  end

  it "replaces the streams on a re-probe rather than duplicating them" do
    root = build_root("a.mp4" => "h264_aac.mp4")
    file = discovered(create_library(household: household, roots: root), File.join(root, "a.mp4"))
    2.times { described_class.new(file.reload).call }
    expect(file.media_streams.count).to eq(2)
  end

  # Sonarr's upgrade replaces a file in
  # place. The old encode's keyframes and optimized version mustn't stand in
  # for the new one's.
  it "forgets what was worked out from the old content when the file at the path is replaced" do
    root = build_root("a.mkv" => "h264_aac_ac3_subs.mkv")
    path = File.join(root, "a.mkv")
    file = discovered(create_library(household: household, roots: root), path)
    described_class.new(file).call
    Media::KeyframeIndex.store(file.reload, [ 0, 1000 ], Media::KeyframeIndex::Source::Cues)
    version = OptimizedVersion.create!(household: household, media_file: file, state: "ready", height: 1080, size: 10)
    FileUtils.mkdir_p(version.path.dirname)
    File.write(version.path, "old encode")

    # Probed again unchanged: everything stays.
    described_class.new(file.reload).call
    expect(file.reload.keyframes).to eq([ 0, 1000 ])
    expect(version.reload.state).to eq("ready")

    # Sonarr's doing, not Stream's.
    FileUtils.cp(media_fixture("h264_dts.mkv"), path)
    settle_library_roots!
    described_class.new(file.reload).call
    expect(file.reload).to have_attributes(keyframes: nil, keyframes_source: nil)
    expect(version.reload.state).to eq("queued")
    expect(version.path).not_to exist
  end

  it "keeps a truncated file playable, with a warning for Needs attention" do
    root = build_root("cut.mkv" => "truncated.mkv")
    file = discovered(create_library(household: household, roots: root), File.join(root, "cut.mkv"))
    expect(described_class.new(file).call).to eq(described_class::Outcome::Probed)
    expect(file.reload).to have_attributes(state: "probed", last_error: start_with("The file ends early"))
  end

  it "leaves a file a busy share timed out on to be probed again, never broken" do
    root = build_root("slow.mkv" => "h264_aac_ac3_subs.mkv")
    file = discovered(create_library(household: household, roots: root), File.join(root, "slow.mkv"))
    allow(Media::Probe).to receive(:run).and_raise(ToolRunner::Timeout, "ffprobe took longer than 120s")
    expect { described_class.new(file).call }.to raise_error(ToolRunner::Timeout)
    expect(file.reload).to have_attributes(state: "discovered", last_error: start_with("Probing timed out"))
  end

  it "says why when the share won't read a file, and leaves it to be probed again" do
    root = build_root("unreadable.mkv" => "h264_aac_ac3_subs.mkv")
    file = discovered(create_library(household: household, roots: root), File.join(root, "unreadable.mkv"))
    allow(Media::Fingerprint).to receive(:compute).and_raise(Errno::EIO)
    expect { described_class.new(file).call }.to raise_error(Errno::EIO)
    expect(file.reload).to have_attributes(state: "discovered", last_error: start_with("Couldn't read the file"))
    expect(file.analysis_runs.sole).to have_attributes(step: "probe", status: "failed", error: include("Errno::EIO"))
  end

  it "marks a broken file broken, records the failure and never stamps success" do
    root = build_root
    path = File.join(root, "bad.mkv")
    File.binwrite(path, Random.new(1).bytes(64 * 1024))
    settle_library_roots!
    file = discovered(create_library(household: household, roots: root), path)

    expect(described_class.new(file).call).to eq(described_class::Outcome::Broken)

    expect(file.reload).to have_attributes(state: "broken", last_error: be_present)
    expect(file.analysis_runs.sole).to have_attributes(status: "failed", finished_at: nil, consecutive_failures: 1)
    expect(ActivityEntry.where(event: "media_file.broken").count).to eq(1)
  end

  it "moves a missing file's row to the new path, keeping its id, when the same content turns up" do
    root = build_root("old/Heat.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    old_path = File.join(root, "old/Heat.mkv")
    original = discovered(library, old_path)
    described_class.new(original).call

    new_path = File.join(root, "new/Heat (1995).mkv")
    FileUtils.mkdir_p(File.dirname(new_path))
    FileUtils.mv(old_path, new_path)
    settle_library_roots!
    original.update!(state: "missing", missing_since: Time.current)
    arrival = discovered(library, new_path)

    expect(described_class.new(arrival).call).to eq(described_class::Outcome::Moved)

    expect(MediaFile.exists?(arrival.id)).to be(false)
    expect(original.reload).to have_attributes(path: new_path, state: "probed", missing_since: nil)
    expect(ActivityEntry.where(event: "media_file.moved").sole.summary).to include("moved from")
  end

  # The change detector doesn't look for removals, so a renamed folder's
  # targeted scan reaches the new path while the old row still reads probed.
  it "moves a row whose file has gone even before a scan has called it missing" do
    root = build_root("old/Heat.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    old_path = File.join(root, "old/Heat.mkv")
    original = discovered(library, old_path)
    described_class.new(original).call

    new_path = File.join(root, "new/Heat (1995).mkv")
    FileUtils.mkdir_p(File.dirname(new_path))
    FileUtils.mv(old_path, new_path)
    settle_library_roots!
    arrival = discovered(library, new_path)

    expect(described_class.new(arrival).call).to eq(described_class::Outcome::Moved)

    expect(MediaFile.exists?(arrival.id)).to be(false)
    expect(original.reload).to have_attributes(path: new_path, state: "probed")
  end

  it "keeps two copies of one file apart" do
    root = build_root("a/Heat.mkv" => "h264_aac.mp4", "b/Heat.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    first = discovered(library, File.join(root, "a/Heat.mkv"))
    described_class.new(first).call
    second = discovered(library, File.join(root, "b/Heat.mkv"))

    expect(described_class.new(second).call).to eq(described_class::Outcome::Probed)

    expect(MediaFile.where(id: [ first.id, second.id ]).pluck(:state)).to eq(%w[probed probed])
  end

  # A dropped share reads as "not there" too.
  it "doesn't take a file for moved when its library's folder can't be read" do
    root = build_root("a/Heat.mkv" => "h264_aac.mp4")
    gone = build_root("Heat.mkv" => "h264_aac.mp4")
    away = create_library(household: household, roots: gone, name: "Away")
    original = discovered(away, File.join(gone, "Heat.mkv"))
    described_class.new(original).call
    FileUtils.rm_rf(gone)
    settle_library_roots!
    arrival = discovered(create_library(household: household, roots: root, name: "Here"), File.join(root, "a/Heat.mkv"))

    expect(described_class.new(arrival).call).to eq(described_class::Outcome::Probed)

    expect(original.reload.path).to eq(File.join(gone, "Heat.mkv"))
  end

  # A file that never read has no streams: Probed would leave it that way
  # for good, never matched.
  it "probes a moved file that was never read, rather than calling it probed" do
    root = build_root("old/Heat.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    path = File.join(root, "old/Heat.mkv")
    original = discovered(library, path)
    fingerprint = Media::Fingerprint.compute(path)
    original.update!(state: "missing", missing_since: Time.current, fingerprint: fingerprint, probed_at: nil)
    new_path = File.join(root, "new/Heat.mkv")
    FileUtils.mkdir_p(File.dirname(new_path))
    FileUtils.mv(path, new_path)
    settle_library_roots!
    arrival = discovered(library, new_path)

    expect(described_class.new(arrival).call).to eq(described_class::Outcome::Moved)

    expect(original.reload).to have_attributes(path: new_path, state: "discovered")
    expect(enqueued_jobs.map { |job| job.slice("job_class", "arguments") })
      .to include("job_class" => "ProbeMediaFileJob", "arguments" => [ original.id ])
  end

  it "does nothing to a file that vanished before its probe ran" do
    root = build_root("a.mp4" => "h264_aac.mp4")
    file = discovered(create_library(household: household, roots: root), File.join(root, "a.mp4"))
    FileUtils.rm(file.path)
    settle_library_roots!
    expect(described_class.new(file).call).to eq(described_class::Outcome::Vanished)
    expect(file.reload.state).to eq("discovered")
  end
end
