# typed: false
# frozen_string_literal: true

require "rails_helper"

# Plays the person dropping files onto the share, so it changes the roots.
RSpec.describe Libraries::ChangeDetector, :changes_library_root do
  let(:household) { Household.create!(name: "Watch") }
  # Past SETTLE for anything the example just wrote.
  let(:later) { Time.current + 5.minutes }

  def look(library, now: later) = described_class.new(library, now: now).call

  def scans = enqueued_jobs.select { |job| job["job_class"] == "ScanLibraryJob" }.map { |job| job["arguments"].drop(1) }

  # Something new in a folder, and the folder's mtime moved (to a known
  # second, so two writes inside one second still read as a change).
  def drop(root, relative, at: Time.current + 1.minute)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(media_fixture("h264_aac.mp4"), path)
    File.utime(at.to_time, at.to_time, File.dirname(path))
  end

  it "only records on its first look, then scans just the folders that changed since" do
    root = build_root("Funhaus/old.mp4" => "h264_aac.mp4", "Fireship/a.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root, kind: "channels")

    expect(look(library)).to eq([])
    expect(FolderListing.find_by!(library: library, root: root).entries.keys).to contain_exactly("Funhaus", "Fireship")

    drop(root, "Northernlion/new.mp4")
    drop(root, "Funhaus/another.mp4")
    clear_enqueued_jobs

    expect(look(library)).to contain_exactly(File.join(root, "Northernlion"), File.join(root, "Funhaus"))
    expect(scans).to contain_exactly([ File.join(root, "Northernlion") ], [ File.join(root, "Funhaus") ])

    # Nothing moved since: nothing to scan.
    clear_enqueued_jobs
    expect(look(library)).to eq([])
    expect(scans).to eq([])
  end

  it "waits for a folder still being copied into, however old the copied files say they are" do
    root = build_root("Fireship/a.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root, kind: "channels")
    look(library)

    # A copy that keeps the files' own mtimes, years back: only ctime says
    # it's being written now.
    drop(root, "Funhaus/2018.mp4", at: Time.utc(2018, 5, 1))
    File.utime(Time.utc(2018, 5, 1), Time.utc(2018, 5, 1), File.join(root, "Funhaus/2018.mp4"))

    expect(look(library, now: Time.current)).to eq([])
    expect(look(library)).to eq([ File.join(root, "Funhaus") ])
  end

  it "looks into each show's folders, and a new show is one scan of the show" do
    root = build_root("Bluey/Season 01/Bluey S01E01.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root, kind: "shows")
    look(library)
    expect(FolderListing.find_by!(library: library).entries.keys).to contain_exactly("Bluey", "Bluey/Season 01")

    drop(root, "Bluey/Season 01/Bluey S01E02.mkv")
    drop(root, "Severance/Season 01/Severance S01E01.mkv")
    File.utime((later - 1.minute).to_time, (later - 1.minute).to_time, File.join(root, "Severance"))

    expect(look(library)).to contain_exactly(File.join(root, "Bluey/Season 01"), File.join(root, "Severance"))
  end

  it "lists a library of more shows than it looks up at once, and finds the one season that changed" do
    files = (1..20).to_h { |i| [ "Show #{i}/Season 01/Show #{i} S01E01.mkv", "h264_aac.mp4" ] }
    root = build_root(files.merge("Loose.mkv" => "h264_aac.mp4"))
    library = create_library(household: household, roots: root, kind: "shows")
    look(library)
    expect(FolderListing.find_by!(library: library).entries.keys)
      .to match_array([ "Loose.mkv" ] + (1..20).flat_map { |i| [ "Show #{i}", "Show #{i}/Season 01" ] })

    drop(root, "Show 17/Season 01/Show 17 S01E02.mkv")

    expect(look(library)).to eq([ File.join(root, "Show 17/Season 01") ])
  end

  it "takes a share that reads as empty for one that has dropped off, and many changes for one full scan" do
    root = build_root("Heat (1995)/Heat.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    look(library)

    FileUtils.rm_rf(File.join(root, "Heat (1995)"))
    expect(look(library)).to eq([])
    expect(FolderListing.find_by!(library: library).entries.keys).to eq([ "Heat (1995)" ])

    FileUtils.rm_rf(root)
    expect(look(library)).to eq([])

    FileUtils.mkdir_p(root)
    (described_class::MAX_TARGETED + 1).times { |i| drop(root, "Film #{i} (2000)/Film.mkv") }
    clear_enqueued_jobs
    expect(look(library)).to eq([ root ])
    expect(scans).to eq([ [] ])
  end
end
