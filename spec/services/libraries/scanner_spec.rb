# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Libraries::Scanner do
  let(:household) { Household.create!(name: "Scan") }

  def scan(library, subpath: nil) = described_class.new(library, subpath: subpath).call

  def paths(library) = MediaFile.where(library: library).order(:path).pluck(:path, :state)

  it "adds every video under the roots and queues each for probing" do
    root = build_root("Heat (1995)/Heat.mkv" => "h264_aac_ac3_subs.mkv", "Alien (1979)/Alien.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)

    counts = scan(library)

    expect(counts.to_h).to include("seen" => 2, "added" => 2)
    expect(paths(library).map(&:last)).to all(eq("discovered"))
    expect(enqueued_jobs.count { |job| job["job_class"] == "ProbeMediaFileJob" }).to eq(2)
  end

  it "skips samples, hidden files, non-video files and NAS housekeeping folders" do
    root = build_root(
      "Heat (1995)/Heat.mkv" => "h264_aac.mp4",
      "Heat (1995)/Heat-sample.mkv" => "h264_aac.mp4",
      "Heat (1995)/Sample/clip.mkv" => "h264_aac.mp4",
      "Heat (1995)/._Heat.mkv" => "h264_aac.mp4",
      "Heat (1995)/@eaDir/Heat.mkv" => "h264_aac.mp4",
      "Heat (1995)/#recycle/old.mkv" => "h264_aac.mp4",
      "Heat (1995)/notes.txt" => "manifest.json"
    )
    library = create_library(household: household, roots: root)

    scan(library)

    expect(paths(library).map { |path, _| path.delete_prefix(root) }).to eq([ "/Heat (1995)/Heat.mkv" ])
  end

  # The lesson of the class, a level down: a folder the share wouldn't list
  # isn't an empty one, so what Stream knows under it stays as it is.
  describe "a share that misbehaves part way through" do
    let(:root) { build_root("Heat/Heat.mkv" => "h264_aac.mp4", "Alien/Alien.mkv" => "h264_aac.mp4") }
    let(:library) { create_library(household: household, roots: root) }

    before do
      scan(library)
      MediaFile.where(library: library).update_all(state: "probed")
      allow(Dir).to receive(:children).and_call_original
      allow(File).to receive(:lstat).and_call_original
    end

    def state_of(name) = MediaFile.find_by!(path: File.join(root, name)).state

    it "leaves what's under a folder it couldn't read, and carries on with the rest" do
      FileUtils.cp(media_fixture("h264_aac.mp4"), File.join(root, "Alien/Alien 2.mkv"))
      settle_library_roots!
      allow(Dir).to receive(:children).with(File.join(root, "Heat")).and_raise(Errno::EIO)

      counts = scan(library)

      expect(state_of("Heat/Heat.mkv")).to eq("probed")
      expect(counts.missing).to eq(0)
      expect(counts.added).to eq(1)
      expect(counts.unread).to eq([ File.join(root, "Heat") ])
    end

    it "leaves a file the share wouldn't answer for" do
      answering = false
      allow(File).to receive(:lstat).with(File.join(root, "Heat/Heat.mkv")).and_wrap_original do |original, path|
        answering ? original.call(path) : raise(Errno::ETIMEDOUT)
      end

      expect(scan(library).unread).to eq([ File.join(root, "Heat/Heat.mkv") ])

      answering = true
      expect(state_of("Heat/Heat.mkv")).to eq("probed")
    end

    it "deletes nothing past its grace on a walk that couldn't see everything" do
      MediaFile.find_by!(path: File.join(root, "Heat/Heat.mkv")).update!(state: "missing", missing_since: 2.years.ago)
      allow(Dir).to receive(:children).with(File.join(root, "Heat")).and_raise(Errno::EIO)

      expect(scan(library).purged).to eq(0)

      expect(MediaFile.exists?(path: File.join(root, "Heat/Heat.mkv"))).to be(true)
    end

    # A folder removed during the walk is simply gone.
    it "takes a folder that went while it walked as gone" do
      allow(Dir).to receive(:children).with(File.join(root, "Heat")).and_raise(Errno::ENOENT)

      counts = scan(library)

      expect(state_of("Heat/Heat.mkv")).to eq("missing")
      expect(counts.unread).to be_empty
    end

    # A mount dropping mid-walk reads the same, until the root is looked at
    # again and is empty.
    it "fails the scan when the root itself went from under the walk" do
      listed = %w[Alien Heat]
      allow(Dir).to receive(:children).with(root).and_wrap_original { |_original, _path| listed.tap { listed = [] } }
      allow(Dir).to receive(:children).with(File.join(root, "Alien")).and_raise(Errno::ENOENT)
      answering = false
      allow(File).to receive(:lstat).with(File.join(root, "Heat")).and_wrap_original do |original, path|
        answering ? original.call(path) : raise(Errno::ENOENT)
      end

      expect { scan(library) }.to raise_error(described_class::RootUnavailable)

      answering = true
      expect(MediaFile.where(library: library).pluck(:state).uniq).to eq([ "probed" ])
    end

    it "fails the scan when the root can't be listed at all" do
      allow(Dir).to receive(:children).with(root).and_raise(Errno::ETIMEDOUT)

      expect { scan(library) }.to raise_error(described_class::RootUnavailable)
    end
  end

  it "takes a link to a video as the video, and doesn't follow a link to a folder" do
    outside = build_root("Kept/Kept.mkv" => "h264_aac.mp4")
    root = build_root("Heat/Heat.mkv" => "h264_aac.mp4")
    File.symlink(File.join(outside, "Kept/Kept.mkv"), File.join(root, "Heat/Linked.mkv"))
    File.symlink(File.join(outside, "Kept"), File.join(root, "Linked folder"))
    File.symlink(File.join(root, "nowhere.mkv"), File.join(root, "Heat/Dangling.mkv"))
    library = create_library(household: household, roots: root)

    scan(library)

    expect(paths(library).map { |path, _| path.delete_prefix(root) }).to eq([ "/Heat/Heat.mkv", "/Heat/Linked.mkv" ])
    expect(MediaFile.find_by!(path: File.join(root, "Heat/Linked.mkv")).size).to eq(File.size(File.join(outside, "Kept/Kept.mkv")))
  end

  it "reads each video once, however a file is told from a folder" do
    root = build_root("Heat/Heat.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    allow(File).to receive(:lstat).and_call_original
    allow(File).to receive(:stat).and_call_original
    allow(File).to receive(:directory?).and_call_original

    scan(library)

    path = File.join(root, "Heat/Heat.mkv")
    expect(File).to have_received(:lstat).with(path).once
    expect(File).not_to have_received(:stat).with(path)
    expect(File).not_to have_received(:directory?).with(path)
  end

  it "writes a new file's sidecars with the file, rather than again after it" do
    root = build_root("Heat/Heat.mkv" => "h264_aac.mp4")
    File.write(File.join(root, "Heat/Heat.en.srt"), "")
    library = create_library(household: household, roots: root)

    updates = count_queries(matching: /UPDATE.*sidecar_subtitles/) { scan(library) }

    expect(updates).to be_empty
    expect(MediaFile.find_by!(path: File.join(root, "Heat/Heat.mkv")).sidecar_subtitles).to eq([ "Heat.en.srt" ])
  end

  it "remembers each video's sidecar subtitles, and what's arrived beside it since" do
    root = build_root("Heat (1995)/Heat (1995).mkv" => "h264_aac.mp4", "Alien (1979)/Alien.mp4" => "h264_aac.mp4")
    File.write(File.join(root, "Heat (1995)/Heat (1995).en.srt"), "")
    File.write(File.join(root, "Heat (1995)/Heat (1995).es.forced.srt"), "")
    File.write(File.join(root, "Heat (1995)/Other.en.srt"), "")
    library = create_library(household: household, roots: root)
    scan(library)
    heat = MediaFile.find_by!(path: File.join(root, "Heat (1995)/Heat (1995).mkv"))
    expect(heat.sidecar_subtitles).to eq([ "Heat (1995).en.srt", "Heat (1995).es.forced.srt" ])
    expect(MediaFile.find_by!(path: File.join(root, "Alien (1979)/Alien.mp4")).sidecar_subtitles).to eq([])

    File.write(File.join(root, "Heat (1995)/Heat (1995).fr.srt"), "")
    File.delete(File.join(root, "Heat (1995)/Heat (1995).en.srt"))
    settle_library_roots!
    scan(library)
    expect(heat.reload.sidecar_subtitles).to eq([ "Heat (1995).es.forced.srt", "Heat (1995).fr.srt" ])

    # Nothing changed: what the walk read is enough, with nothing written.
    settle_library_roots!
    writes = count_queries(matching: /sidecar_subtitles/) { scan(library) }
    expect(writes.size).to eq(1) # the walk's own read
  end

  it "requeues a changed file and leaves an unchanged probed file alone" do
    root = build_root("a.mp4" => "h264_aac.mp4", "b.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    scan(library)
    MediaFile.update_all(state: "probed")
    clear_enqueued_jobs

    File.open(File.join(root, "b.mp4"), "ab") { |f| f.write("more") }
    settle_library_roots!
    counts = scan(library)

    expect(counts.to_h).to include("changed" => 1, "added" => 0)
    expect(paths(library)).to eq([ [ File.join(root, "a.mp4"), "probed" ], [ File.join(root, "b.mp4"), "discovered" ] ])
    expect(enqueued_jobs.count { |job| job["job_class"] == "ProbeMediaFileJob" }).to eq(1)
  end

  it "marks vanished files missing, and a reappearing one discovered again" do
    root = build_root("a.mp4" => "h264_aac.mp4", "b.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    scan(library)

    moved_away = File.join(build_root, "b.mp4") # somewhere else, cleaned up after
    FileUtils.mv(File.join(root, "b.mp4"), moved_away)
    expect(scan(library).missing).to eq(1)
    missing = MediaFile.find_by(path: File.join(root, "b.mp4"))
    expect(missing).to have_attributes(state: "missing", missing_since: be_present)

    FileUtils.mv(moved_away, File.join(root, "b.mp4"))
    scan(library)
    expect(missing.reload).to have_attributes(state: "discovered", missing_since: nil)
  end

  it "refuses to trust a root that reads as empty while files are known there" do
    root = build_root("a.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    scan(library)
    FileUtils.rm(File.join(root, "a.mp4")) # what an unmounted share looks like
    settle_library_roots!

    expect { scan(library) }.to raise_error(described_class::RootUnavailable, /Is the share mounted/)
    expect(MediaFile.find_by(library: library).state).to eq("discovered")
  end

  it "fails on a root that has disappeared entirely" do
    root = build_root("a.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    FileUtils.rm_rf(root)

    expect { scan(library) }.to raise_error(described_class::RootUnavailable)
  end

  it "scans only the named path on a targeted scan, and marks nothing outside it missing" do
    root = build_root("Show A/e1.mkv" => "h264_aac.mp4", "Show B/e1.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root, kind: "shows")
    scan(library)
    FileUtils.cp(media_fixture("h264_aac.mp4"), File.join(root, "Show A/e2.mkv"))
    FileUtils.rm(File.join(root, "Show B/e1.mkv"))
    settle_library_roots!

    counts = scan(library, subpath: File.join(root, "Show A"))

    expect(counts.to_h).to include("added" => 1, "missing" => 0)
    expect(MediaFile.find_by(path: File.join(root, "Show B/e1.mkv")).state).to eq("discovered")
  end

  it "rejects a targeted path outside the library" do
    library = create_library(household: household, roots: build_root("a.mp4" => "h264_aac.mp4"))
    expect { scan(library, subpath: "/etc") }.to raise_error(described_class::RootUnavailable, /not inside/)
  end

  it "deletes files missing past the grace period on a full scan" do
    root = build_root("a.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    stale = MediaFile.create!(household: household, library: library, path: File.join(root, "gone.mkv"), size: 1,
      mtime: Time.current, state: "missing", missing_since: (MediaFile::MISSING_GRACE + 1.day).ago)

    expect(scan(library).purged).to eq(1)
    expect(MediaFile.exists?(stale.id)).to be(false)
  end
end
