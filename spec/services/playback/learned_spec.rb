# typed: false
# frozen_string_literal: true

require "rails_helper"

# What plays teach, and how carefully.
RSpec.describe Playback::Learned do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { Household.create!(name: "Learn") }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:chrome) { "Chrome 141 on macOS" }

  def mkv(name)
    file = MediaFile.create!(household: household, library: library, path: "/m/#{name}.mkv", size: 1, mtime: Time.current, state: "probed",
      container: "matroska,webm")
    file.media_streams.create!(index: 0, kind: "video", codec: "hevc", profile: "Main 10", pixel_format: "yuv420p10le", field_order: "progressive")
    file.media_streams.create!(index: 1, kind: "audio", codec: "eac3", channels: 6, default: true)
    file.reload
  end

  def session(file, method: "remux", failure: nil, client: chrome)
    profile = Profile.default_for(household)
    movie = Movie.create!(household: household, library: library, title: "T")
    PlaybackSession.create!(household: household, profile: profile, playable: movie, media_file: file, method: method, decision: {},
      started_at: Time.current, last_seen_at: Time.current, client_class: client, failure_class: failure, failure_cause: failure && "MediaError 3")
  end

  it "names a client by its browser, major version and platform" do
    expect(Playback::ClientClass.from("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/141.0.7390.54 Safari/537.36"))
      .to eq("Chrome 141 on macOS")
    expect(Playback::ClientClass.from("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15")).to eq("Safari 18 on macOS")
    expect(Playback::ClientClass.from("StreamTV/1.0 (Apple TV; tvOS)")).to eq("Apple TV app 1")
  end

  it "reads what files like this one taught in one query, however many rungs (APPLETV_STALLS R5)" do
    file = mkv("a")
    3.times { |n| described_class.failed!(session(mkv("other-#{n}"), failure: "decode")) }
    file.media_streams.load
    queries = count_queries(matching: /playabilities/) { described_class.constraints_for(file, chrome) }
    expect(queries.size).to eq(2)
  end

  it "skips a rung that failed for a file on this client, and not on another, until it works or the probation ends" do
    file = mkv("a")
    described_class.failed!(session(file, failure: "decode"))

    constraints, why = described_class.constraints_for(file, chrome)
    expect(constraints).to have_attributes(no_direct: true, convert_video: true)
    expect(why).to eq("Repackaging failed for this file on Chrome 141 on macOS before — skipped")
    expect(described_class.constraints_for(file, "Safari 18 on macOS").first.none?).to be(true)

    travel(Playability::PROBATION + 1.day) { expect(described_class.constraints_for(file, chrome).first.none?).to be(true) }

    described_class.played!(session(file))
    expect(described_class.constraints_for(file, chrome).first.none?).to be(true)
  end

  it "skips a rung for a format only once two of its files have failed there, and never over a file's own success" do
    first = mkv("a")
    second = mkv("b")
    other = mkv("c")
    described_class.failed!(session(first, failure: "unsupported"))
    expect(described_class.constraints_for(other, chrome).first.none?).to be(true)

    described_class.failed!(session(second, failure: "unsupported"))
    constraints, why = described_class.constraints_for(other, chrome)
    expect(constraints).to have_attributes(no_direct: true, convert_audio: true)
    expect(why).to eq("Repackaging failed for 2 files like this on Chrome 141 on macOS — skipped")

    # A file that played that way keeps playing that way.
    described_class.played!(session(other))
    expect(described_class.constraints_for(other, chrome).first.none?).to be(true)
    # And a success on the format after the failures lifts it for the rest.
    fourth = mkv("d")
    expect(described_class.constraints_for(fourth, chrome).first.none?).to be(true)
  end

  it "learns the hardware encoder failed, and converts in software next time" do
    file = mkv("a")
    described_class.failed!(session(file, method: "video_transcode", failure: "server"))
    expect(described_class.constraints_for(file, chrome).first).to have_attributes(convert_video: true, convert_audio: true)
  end
end
