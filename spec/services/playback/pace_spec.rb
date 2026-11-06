# typed: false
# frozen_string_literal: true

require "rails_helper"

# docs/APPLETV_STALLS.md › R1: how fast a run reads, for its share and its viewer.
RSpec.describe Playback::Pace do
  def pace(speed: nil, bitrate: 2_000_000.0, standby: false)
    described_class.choose(described_class.new(rate: 2.0, burst: 60.0, root: "/media/far", share_speed: speed, bitrate: bitrate,
      standby: standby))
  end

  it "keeps the 60 s burst and twice real time on a share that reads the film many times over" do
    expect(pace(speed: 96_000_000.0)).to have_attributes(rate: 2.0, burst: 60.0, slow?: false)
  end

  it "keeps them on a share nothing has measured yet" do
    expect(pace(speed: nil)).to have_attributes(rate: 2.0, burst: 60.0, slow?: false)
  end

  it "sizes the burst to a few seconds of reading on a share that barely outruns the film" do
    # The stock NAS: 6.4 MB/s for a 2 MB/s 720p file is 3.2× real time.
    slow = pace(speed: 6_400_000.0)
    expect(slow).to have_attributes(rate: 2.0, slow?: true)
    expect(slow.burst).to eq(25.6)
  end

  it "calls a file behind only when the share clearly can't deliver it" do
    # The Fellowship remux, 9.2 MB/s, on the stock NAS's measured 1.25.
    expect(pace(speed: 1_250_000.0, bitrate: 9_200_000.0).falls_behind?).to be(true)
    # A reading comes in low: an ordinary 1080p file on that reading plays fine.
    expect(pace(speed: 1_250_000.0, bitrate: 2_000_000.0).falls_behind?).to be(false)
    expect(pace(speed: nil, bitrate: 9_200_000.0).falls_behind?).to be(false)
  end

  it "doesn't throttle a run that only repackages, on any share (R2)" do
    base = described_class.new(rate: 2.0, burst: 60.0, share_speed: 6_400_000.0, bitrate: 2_000_000.0)
    expect(described_class.choose(base, converting: false)).to have_attributes(throttled: false)
    expect(described_class.choose(base, converting: true)).to have_attributes(throttled: true, burst: 25.6)
    standby = described_class.new(rate: 2.0, burst: 60.0, standby: true)
    expect(described_class.choose(standby, converting: false)).to have_attributes(throttled: true, rate: 1.0, burst: 20.0)
  end

  it "never bursts less than the next segments, however slow the share" do
    expect(pace(speed: 1_000_000.0).burst).to eq(described_class::MIN_BURST)
  end

  it "reads a channel tuned ahead at real time, just enough to preroll on a slow share" do
    expect(pace(speed: 6_400_000.0, standby: true)).to have_attributes(rate: 1.0, burst: 6.0)
  end

  it "reads a channel tuned ahead past what the deck buffers for it on a share that isn't slow" do
    expect(pace(speed: 96_000_000.0, standby: true)).to have_attributes(rate: 1.0, burst: 20.0)
    expect(pace(speed: nil, standby: true)).to have_attributes(rate: 1.0, burst: 20.0)
  end

  it "finds a file's root by its stored path and its bytes per second of film" do
    household = Household.create!(name: "Stream")
    library = create_library(household: household, roots: build_root)
    root = library.roots.first
    file = MediaFile.create!(household: household, library: library, path: "#{root}/Heat (1995)/Heat.mkv", size: 4_000_000_000,
      duration_seconds: 2000.0, mtime: Time.current, state: "discovered")
    expect(described_class.root_of(file)).to eq(root)
    expect(described_class.bitrate_of(file)).to eq(2_000_000.0)
    file.bit_rate = 8_000_000
    expect(described_class.bitrate_of(file)).to eq(1_000_000.0)
    file.path = "#{root}-other/Heat.mkv"
    expect(described_class.root_of(file)).to be_nil
  end
end
