# typed: false
# frozen_string_literal: true

require "rails_helper"

# Teams' games on a Grid channel (PROPOSAL §7.7, §7.8): chosen in its
# editor, in the guide as their matchups, and tuned in as the team's
# stream for as long as the game's slot runs.
RSpec.describe "Games on Grid channels", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:schedule) { instance_double(Mlb::Schedule) }
  let(:first_pitch) { Time.current.change(sec: 0) - 20.minutes }
  let(:brewers) do
    Mlb::TeamStreams.for(household.id, 158, "Milwaukee Brewers").tap do |stream|
      stream.update!(probed_at: Time.current)
      stream.media_streams.create!(index: 0, kind: "audio", codec: "aac", channels: 2)
      stream.media_streams.create!(index: 1, kind: "video", codec: "h264", bit_depth: 8, height: 720)
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
    allow(EnsureMlbTeamStreamsJob).to receive(:perform_later)
    MlbSetting.create!(household: household, username: "fan@example.com", password: "secret")
    allow(Mlb::Schedule).to receive(:new).and_return(schedule)
    allow(schedule).to receive(:teams).and_return([ { "id" => 112, "name" => "Chicago Cubs" }, { "id" => 158, "name" => "Milwaukee Brewers" } ])
    game = {
      "gamePk" => 776_001, "gameDate" => first_pitch.utc.iso8601, "officialDate" => first_pitch.to_date.iso8601, "gameType" => "R",
      "doubleHeader" => "N", "gameNumber" => 1, "status" => { "abstractGameState" => "Live", "detailedState" => "In Progress" },
      "teams" => { "away" => { "team" => { "id" => 112, "name" => "Chicago Cubs", "teamName" => "Cubs" } },
                   "home" => { "team" => { "id" => 158, "name" => "Milwaukee Brewers", "teamName" => "Brewers" } } }
    }
    allow(schedule).to receive(:games) { |date| date == first_pitch.in_time_zone(AppSetting.cached.zone).to_date ? [ game ] : [] }
  end

  def make_channel
    brewers
    library = create_library(household: household, roots: build_root, name: "Films")
    file = MediaFile.create!(household: household, library: library, path: "/films/a.mkv", size: 1000, mtime: Time.current,
      state: "probed", duration_seconds: 6000.0, container: "matroska,webm")
    file.media_streams.create!(index: 0, kind: "video", codec: "h264", bit_depth: 8, height: 1080)
    file.media_streams.create!(index: 1, kind: "audio", codec: "aac", channels: 2)
    Movie.create!(household: household, library: library, title: "Major League").editions.create!(media_file: file)
    post "/api/v1/stations", params: { number: "41", name: "Brewers", mlb_team_ids: [ 158 ],
      blocks: [ { layer: "base", source: {}, ordering: "shuffle" } ] }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:created), response.body
    Station.find(json["id"])
  end

  it "offers the clubs to the editor, and keeps the ones chosen" do
    get "/api/v1/stations/options", headers: auth_headers(admin)
    expect(json["mlb_teams"]).to eq([ { "id" => 112, "name" => "Chicago Cubs" }, { "id" => 158, "name" => "Milwaukee Brewers" } ])

    station = make_channel
    expect(json).to include("mlb_team_ids" => [ 158 ])
    expect(station.airings.where(mlb_game_pk: 776_001)).to exist
  end

  it "shows the game in the guide as its matchup" do
    station = make_channel
    get "/api/v1/guide", headers: auth_headers(admin)

    row = json["stations"].find { |candidate| candidate["id"] == station.id }
    expect(row["airings"].first).to include("kind" => "live_stream", "title" => "Cubs at Brewers", "subtitle" => "MLB.tv",
      "playable_id" => brewers.id, "reason" => "Milwaukee Brewers baseball")
  end

  it "tunes in as the team's stream, with the game's slot and what follows it" do
    station = make_channel
    airing = station.airing_at(Time.current)
    post "/api/v1/playback_sessions", params: { station_id: station.id, capabilities: { hls: "mse", video: %w[h264], audio: %w[aac] } },
      headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:created), response.body
    expect(json).to include("title" => "Cubs at Brewers", "subtitle" => "MLB.tv")
    expect(json["live_stream"]).to include("id" => brewers.id)
    expect(json["live"]).to include("airing_id" => airing.id, "ends_at" => airing.ends_at.iso8601(3), "next_airing_id" => airing.following.id)
    expect(PlaybackSession.find(json["id"])).to have_attributes(playable: brewers, airing: airing, media_file_id: nil)

    # The slot over, what follows plays from the library.
    following = airing.following
    travel_to(following.starts_at + 1.second) do
      post "/api/v1/playback_sessions", params: { after_airing_id: airing.id, capabilities: { hls: "mse", video: %w[h264], audio: %w[aac] } },
        headers: auth_headers(admin), as: :json
    end
    expect(response).to have_http_status(:created), response.body
    expect(json).to include("title" => "Major League", "live_stream" => nil)
    expect(json.dig("live", "airing_id")).to eq(following.id)
  end

  it "won't let a channel showing a stream carry games too" do
    library = Library.create!(household: household, name: "Cameras", kind: "live")
    camera = LiveStream.create!(household: household, library: library, name: "Door", kind: "camera", url: "rtsp://192.168.1.5/live")
    post "/api/v1/stations", params: { number: "42", name: "Door", live_stream_id: camera.id, mlb_team_ids: [ 158 ] },
      headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to include("A channel showing a stream can't also carry games")
  end
end
