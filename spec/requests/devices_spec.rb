# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Device capabilities", type: :request do
  let(:household) { create_household }
  let(:member) { create_user(household: household) }
  let(:headers) { { "Authorization" => "Bearer #{ApiToken.generate(user: member, name: 'hook').token}" } }

  def device(key, seen:, household: self.household, **attributes)
    Device.create!(household: household, client_key: key, name: "Chrome on macOS", last_seen_at: seen, **attributes)
  end

  it "answers a member's API token with the parsed profile of each device" do
    seen = 1.hour.ago
    device("tv", seen: seen, label: "Living room TV",
      capabilities: { "hls" => "native", "video" => %w[h264 hevc hevc_10 bogus], "hdr" => %w[hdr10 dolby_vision], "max_height" => 2160 })

    get "/api/v1/devices/capabilities", headers: headers

    expect(response).to have_http_status(:ok)
    expect(json).to contain_exactly(
      a_hash_including(
        "name" => "Living room TV",
        "capabilities" => { "hls" => "native", "containers" => %w[mp4], "video" => %w[h264 hevc hevc_10], "audio" => %w[aac mp3],
                            "max_audio_channels" => 2, "hdr" => %w[hdr10 dolby_vision], "max_height" => 2160,
                            # An older client's one list stands for both paths.
                            "stream_video" => %w[h264 hevc hevc_10], "stream_audio" => %w[aac mp3], "levels" => {}, "smooth" => {} }
      )
    )
    expect(Time.iso8601(json.first["last_seen_at"])).to be_within(1.second).of(seen)
  end

  it "fills an empty capabilities column with the baseline and falls back to the browser's name" do
    device("bare", seen: 1.hour.ago, capabilities: {})

    get "/api/v1/devices/capabilities", headers: headers

    expect(json.first["name"]).to eq("Chrome on macOS")
    expect(json.first["capabilities"]).to eq(Playback::Capabilities::BASELINE.merge(
      "stream_video" => %w[h264], "stream_audio" => %w[aac mp3], "levels" => {}, "smooth" => {}
    ))
  end

  it "lists the last 90 days, most recently seen first" do
    older = device("older", seen: 80.days.ago)
    newer = device("newer", seen: 1.day.ago)
    device("stale", seen: 91.days.ago)

    get "/api/v1/devices/capabilities", headers: headers

    expect(json.map { |row| row["id"] }).to eq([ newer.id, older.id ])
  end

  it "never lists another household's devices" do
    device("theirs", seen: 1.hour.ago, household: create_household)

    get "/api/v1/devices/capabilities", headers: headers

    expect(response).to have_http_status(:ok)
    expect(json).to eq([])
  end

  it "refuses a request without a token" do
    get "/api/v1/devices/capabilities"
    expect(response).to have_http_status(:unauthorized)
  end
end
