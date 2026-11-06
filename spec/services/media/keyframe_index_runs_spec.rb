# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Media::KeyframeIndex do
  let(:household) { Household.create!(name: "Frames") }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:file) do
    MediaFile.create!(household: household, library: library, path: "/x.ts", size: 1, mtime: Time.current, state: "probed", container: "mpegts", duration_seconds: 60)
  end

  def run = AnalysisRun.find_by(media_file: file, step: "keyframes")

  # "Succeeded" would stand for good if the scan it hands over to never ran.
  it "doesn't call a file with no container index done" do
    expect(described_class.index_from_container!(file)).to be_nil

    expect(run.status).to eq("pending")
  end

  it "records a container index as done" do
    allow(described_class).to receive(:from_container).and_return([ [ 0, 2000 ], described_class::Source::Cues ])

    described_class.index_from_container!(file)

    expect(run.status).to eq("succeeded")
    expect(file.reload.keyframes).to eq([ 0, 2000 ])
  end

  it "records a container index that couldn't be read" do
    allow(described_class).to receive(:from_container).and_raise(Errno::EIO)

    expect { described_class.index_from_container!(file) }.to raise_error(Errno::EIO)

    expect(run.status).to eq("failed")
  end

  it "scans under the hold it's given" do
    hold = -> { false }
    allow(Media::Keyframes::PacketScan).to receive(:keyframes_ms).and_return([ 0 ])

    described_class.scan!(file, hold: hold)

    expect(Media::Keyframes::PacketScan).to have_received(:keyframes_ms).with(file.path, hash_including(hold: hold))
    expect(file.reload).to have_attributes(keyframes: [ 0 ], keyframes_source: "packets")
  end

  it "marks a file that can't be scanned through as having none" do
    allow(Media::Keyframes::PacketScan).to receive(:keyframes_ms).and_raise(Media::Keyframes::PacketScan::Incomplete, "damaged")

    described_class.scan!(file, hold: nil)

    expect(file.reload.keyframes_source).to eq("none")
  end
end
