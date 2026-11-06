# typed: false
# frozen_string_literal: true

require "rails_helper"

# The optimizer panel (Playback page): what it's doing, or why it isn't.
RSpec.describe Playback::OptimizerStatus do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { Household.create!(name: "Stream") }
  let(:library) { create_library(household: household, roots: build_root) }

  def file(name, duration: 3600, height: 1080)
    media = MediaFile.create!(household: household, library: library, path: "/m/#{name}", size: 1, mtime: Time.current,
      state: "probed", duration_seconds: duration)
    media.media_streams.create!(index: 0, kind: "video", codec: "hevc", height: height)
    media
  end

  def queue(name, **attributes)
    OptimizedVersion.create!(household: household, media_file: file(name), **attributes)
  end

  before do
    # Noon, quiet hours 1 to 7.
    travel_to Time.zone.parse("2026-10-04 12:00")
    AppSetting.current.update!(optimize_quiet_start_hour: 1, optimize_quiet_end_hour: 7)
    AppSetting.bust_cache!
  end

  def state = described_class.current[:state].serialize

  it "is idle with nothing queued, and says so" do
    expect(described_class.current).to include(state: described_class::State::Idle, message: "Nothing is waiting to be optimized.")
  end

  it "says when nothing is running to encode what's waiting" do
    queue("a.mkv")
    expect(state).to eq("no_transcoder")
    Playback::TranscoderHeartbeat.beat!(encoder: Playback::Encoders::Kind::Software, busy: false)
    expect(state).to eq("waiting_quiet_hours")

    travel 2.minutes
    expect(state).to eq("no_transcoder")
  end

  it "explains a wait: quiet hours, paused, a full budget, a viewer" do
    Playback::TranscoderHeartbeat.beat!(encoder: Playback::Encoders::Kind::Software, busy: false)
    queue("a.mkv")
    status = described_class.current
    expect(status[:state]).to eq(described_class::State::WaitingQuietHours)
    expect(status[:quiet_hours]).to include(now: false, next_start_at: Time.zone.parse("2026-10-05 01:00"),
      ends_at: Time.zone.parse("2026-10-05 07:00"))

    AppSetting.current.update!(optimize_paused: true)
    AppSetting.bust_cache!
    expect(state).to eq("paused")

    AppSetting.current.update!(optimize_paused: false, optimize_quiet_start_hour: 0, optimize_quiet_end_hour: 0, optimize_budget_gb: 1)
    AppSetting.bust_cache!
    expect(state).to eq("starting")
    OptimizedVersion.create!(household: household, media_file: file("b.mkv"), state: "ready", size: 2.gigabytes)
    expect(state).to eq("over_budget")

    queue("c.mkv", origin: "manual")
    expect(state).to eq("starting")
    Playback::TranscoderHeartbeat.beat!(encoder: Playback::Encoders::Kind::Software, busy: true)
    expect(state).to eq("busy")
  end

  it "shows a running encode with its speed and time left, and what the queue will take" do
    queue("a.mkv", state: "encoding", progress: 0.25, started_at: 10.minutes.ago, worker: "nas")
    queue("b.mkv", height: 2160)
    status = described_class.current
    expect(status[:state]).to eq(described_class::State::Encoding)
    expect(status[:encoding].sole).to include(filename: "a.mkv", worker: "nas", speed: 1.5, eta_seconds: 1800)
    # An hour at 1080p: 6 Mb/s of video and 160 kb/s of sound.
    expect(status[:queue]).to include(queued: 1, estimated_bytes: (6_160 * 1000 / 8 * 3600))
  end

  it "counts the interrupted, the failed and the skipped" do
    queue("a.mkv", interruptions: 2, interruption: "quiet hours ended")
    queue("b.mkv", state: "failed")
    queue("c.mkv", state: "skipped")
    expect(described_class.current[:queue]).to include(queued: 1, interrupted: 1, failed: 1, skipped: 1)
  end
end
