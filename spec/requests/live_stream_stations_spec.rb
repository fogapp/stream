# typed: false
# frozen_string_literal: true

require "rails_helper"

# A Grid channel that shows a camera or web stream (PROPOSAL §7.8): one
# program in the guide, the stream, and tuning to it plays the stream.
RSpec.describe "Live stream channels", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera",
      url: "rtsps://192.168.1.1:7441/AbCdEfGhIjKlMnOp?enableSrtp").tap do |live|
      live.media_streams.create!(index: 0, kind: "audio", codec: "aac", channels: 1)
      live.media_streams.create!(index: 1, kind: "video", codec: "h264", bit_depth: 8, height: 2160)
    end
  end

  around do |example|
    Dir.mktmpdir("stream-cache") do |cache|
      @cache = cache
      example.run
    end
  end

  before do
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::Signal).to receive(:relay)
  end

  def make_channel
    post "/api/v1/stations", params: { number: "50", name: "Door cam", live_stream_id: stream.id }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:created), response.body
    Station.find(json["id"])
  end

  it "is offered to the editor, and a channel showing it schedules nothing" do
    stream
    get "/api/v1/stations/options", headers: auth_headers(admin)
    expect(json["live_streams"]).to eq([ { "id" => stream.id, "name" => "Front door", "mlb_team" => false } ])

    station = make_channel
    expect(json).to include("live_stream_id" => stream.id, "last_error" => nil)
    expect(station.airings).to be_empty
  end

  it "is one program in the guide: the stream, across the window" do
    station = make_channel
    from = Time.current.beginning_of_hour
    get "/api/v1/guide?from=#{from.iso8601}&to=#{(from + 3.hours).iso8601}", headers: auth_headers(admin)

    row = json["stations"].find { |candidate| candidate["id"] == station.id }
    expect(row["live_stream_id"]).to eq(stream.id)
    airing = row["airings"].sole
    expect(airing).to include("kind" => "live_stream", "title" => "Front door", "subtitle" => "Live", "playable_id" => stream.id,
      "starts_at" => from.iso8601(3), "ends_at" => (from + 3.hours).iso8601(3))
  end

  it "tunes to the stream, on screen or ahead on standby" do
    station = make_channel
    post "/api/v1/playback_sessions", params: { station_id: station.id, standby: true,
      capabilities: { hls: "mse", video: %w[h264], audio: %w[aac] } }, headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:created)
    expect(json).to include("live" => nil, "method" => "remux")
    expect(json["live_stream"]).to include("id" => stream.id)
    expect(json.dig("source", "url")).to end_with("/live/index.m3u8")
    expect(PlaybackSession.find(json["id"])).to have_attributes(standby: true, playable: stream)
  end

  it "isn't in the lineup of a profile that may not see the stream" do
    station = make_channel
    other = create_library(household: household, roots: build_root)
    kid = Profile.create!(household: household, name: "Kid", library_ids: [ other.id ])

    get "/api/v1/stations", headers: auth_headers(admin).merge(profile_header(kid))
    expect(json.map { |row| row["id"] }).not_to include(station.id)
    post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: auth_headers(admin).merge(profile_header(kid)), as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "keeps the channel, with nothing on, when its stream is removed" do
    station = make_channel
    stream.destroy!
    expect(station.reload.live_stream_id).to be_nil
  end
end
