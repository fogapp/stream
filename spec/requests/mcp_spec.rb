# typed: false
# frozen_string_literal: true

require "rails_helper"

# The MCP surface driven the way a client does (hook:spec/requests/
# mcp_spec.rb): initialize, tools/list, tools/call — stateless, one POST
# each. The headline: "play the next episode of Severance in the living room".
RSpec.describe "MCP surface", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let(:token) { ApiToken.generate(user: admin, name: "Claude").token }
  let!(:grown_up) { Profile.default_for(household) }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:show) { Show.create!(household: household, library: tv, folder: "Severance", title: "Severance", content_rating: "TV-MA") }

  def episode(number)
    season = show.seasons.find_or_create_by!(season_number: 1)
    show.episodes.create!(season: season, season_number: 1, episode_number: number, title: "Episode #{number}").tap do |episode|
      file = MediaFile.create!(household: household, library: tv, path: "/tv/#{number}.mkv", size: 1, mtime: Time.current, state: "probed",
        duration_seconds: 3000)
      episode.editions.create!(media_file: file)
    end
  end

  def screen(label, key: SecureRandom.hex(4))
    Device.create!(household: household, client_key: key, name: "Chrome on Linux", label: label, remote_control: true,
      remote_seen_at: Time.current, last_seen_at: Time.current)
  end

  def rpc(method, params = {}, bearer: token)
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
      headers: { "Authorization" => "Bearer #{bearer}", "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def call_tool(name, arguments = {}, bearer: token)
    rpc("tools/call", { name: name, arguments: arguments }, bearer: bearer)
    expect(response).to have_http_status(:ok)
    result = json.fetch("result")
    [ result, result.dig("content", 0, "text") ]
  end

  def tool_json(name, arguments = {}, bearer: token)
    result, text = call_tool(name, arguments, bearer: bearer)
    expect(result["isError"]).to be_falsey, "#{name} errored: #{text}"
    JSON.parse(text)
  end

  it "refuses anything but an API token, with a bearer challenge" do
    rpc("tools/list", {}, bearer: "nope")
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to include("Bearer")
    rpc("tools/list", {}, bearer: ApiSession.generate!(user: admin, device: "x").token)
    expect(response).to have_http_status(:unauthorized)
  end

  it "introduces itself and lists its tools in a fixed order" do
    rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "spec", version: "1" } })
    expect(json.dig("result", "serverInfo", "name")).to eq("stream")
    expect(json.dig("result", "instructions")).to include("play_on_screen")

    rpc("tools/list")
    expect(json.dig("result", "tools").map { |tool| tool["name"] }).to eq(%w[
      whoami search next_up list_screens play_on_screen control_screen now_playing add_to_watch_later mark_watched
      whats_on live_streams tune_channel
    ])
  end

  it "tells only an admin what the household is watching, as the Stats page does" do
    expect(tool_json("now_playing")).to eq([])

    result, text = call_tool("now_playing", {}, bearer: ApiToken.generate(user: member, name: "Mine").token)
    expect(result["isError"]).to be(true)
    expect(text).to include("admin")
  end

  describe "a read-only token" do
    let(:read_token) { ApiToken.generate(user: admin, name: "wall", scope: ApiToken::Scope::Read).token }

    it "is shown only the tools that look, and refused a call to one that changes things" do
      rpc("tools/list", {}, bearer: read_token)
      expect(json.dig("result", "tools").map { |tool| tool["name"] }).to eq(%w[
        whoami search next_up list_screens now_playing whats_on live_streams
      ])

      rpc("tools/call", { name: "play_on_screen", arguments: { screen: "Living room", kind: "movie", id: "x" } }, bearer: read_token)
      expect(response).to have_http_status(:ok)
      expect(json["error"]["message"]).to include("This token is read-only")
      refused = json["error"]

      # The same answer a tool that does not exist gets.
      rpc("tools/call", { name: "no_such_tool", arguments: {} }, bearer: read_token)
      expect(json["error"]["code"]).to eq(refused["code"])

      whoami = tool_json("whoami", {}, bearer: read_token)
      expect(whoami["user"]["name"]).to eq(admin.name)
    end

    it "takes nothing from a full token" do
      rpc("tools/list")
      expect(json.dig("result", "tools").map { |tool| tool["name"] }).to include("play_on_screen", "mark_watched")
      episode = episode(1)
      tool_json("mark_watched", { kind: "episode", id: episode.id, watched: true })
      expect(WatchState.where(playable: episode).sole.completed_at).to be_present
    end
  end

  it "plays the next episode of Severance in the living room" do
    first = episode(1)
    second = episode(2)
    Playback::Progress.mark(grown_up, first, watched: true)
    living_room = screen("Living room")
    screen("Kitchen")

    whoami = tool_json("whoami")
    expect(whoami["screens"].map { |row| row["name"] }).to contain_exactly("Living room", "Kitchen")
    expect(whoami["profiles"].sole).to include("name" => grown_up.name, "default" => true)

    expect(tool_json("next_up", { show: "severence" })["next"]).to include("kind" => "episode", "id" => second.id, "subtitle" => "S01E02 · Episode 2")

    played = tool_json("play_on_screen", { show: "Severance", screen: "the living room" })
    expect(played).to include("screen" => "Living room", "profile" => grown_up.name)
    command = DeviceCommand.sole
    expect(command).to have_attributes(device_id: living_room.id, kind: "play", user_id: admin.id)
    expect(command.payload).to include("kind" => "episode", "id" => second.id, "profile_id" => grown_up.id)
    expect(ProfileTokens.verify(command.payload["profile_token"], household.id)).to eq(grown_up)

    tool_json("control_screen", { action: "seek", by: -30, screen: "living" })
    expect(DeviceCommand.order(:created_at).last).to have_attributes(kind: "seek", payload: { "by" => -30.0 })
  end

  it "says which screens are listening when the one asked for isn't, or none is" do
    first = episode(1)
    result, text = call_tool("play_on_screen", { kind: "episode", id: first.id, screen: "bedroom" })
    expect(result["isError"]).to be(true)
    expect(text).to include("No screen is listening")

    screen("Living room")
    _, text = call_tool("play_on_screen", { kind: "episode", id: first.id, screen: "bedroom" })
    expect(text).to include("Listening: Living room")
    expect(DeviceCommand.count).to eq(0)
  end

  it "keeps a kid profile's limits, and a PIN profile to admins" do
    episode(1)
    kid = Profile.create!(household: household, name: "Juniper", kind: "kid", max_rating_age: 7)
    expect(tool_json("search", { query: "Severance" })["shows"].size).to eq(1)
    expect(tool_json("search", { query: "Severance", profile: "juni" })["shows"]).to be_empty
    expect(kid).to be_kid

    locked = Profile.create!(household: household, name: "Private")
    locked.change_pin("1234")
    locked.save!
    screen("Living room")
    member_token = ApiToken.generate(user: member, name: "agent").token
    result, text = call_tool("play_on_screen", { show: "Severance", profile: "Private" }, bearer: member_token)
    expect(result["isError"]).to be(true)
    expect(text).to include("has a PIN")
  end

  it "saves to Watch later and marks watched, as a profile" do
    first = episode(1)
    tool_json("add_to_watch_later", { kind: "episode", id: first.id })
    expect(Playlist.watch_later_for(grown_up).playlist_items.sole.item).to eq(first)

    expect(tool_json("mark_watched", { kind: "episode", id: first.id })).to include("watched" => true)
    expect(WatchState.find_by(profile: grown_up, playable: first)).to be_completed
    # Watched is done with: it leaves Watch later.
    expect(tool_json("next_up")["in_progress"]).to be_empty
  end

  it "never reaches another household's titles by id" do
    other = create_household(name: "Next door")
    shelf = create_library(household: other, roots: build_root, kind: "shows", name: "Their TV")
    theirs = Show.create!(household: other, library: shelf, folder: "Theirs", title: "Theirs")
    season = theirs.seasons.create!(season_number: 1)
    their_episode = theirs.episodes.create!(season: season, season_number: 1, episode_number: 1, title: "Pilot")
    their_movie = Movie.create!(household: other, library: shelf, title: "Their film")
    screen("Living room")

    [ [ "episode", their_episode ], [ "movie", their_movie ] ].each do |kind, title|
      %w[mark_watched add_to_watch_later play_on_screen].each do |tool|
        arguments = { kind: kind, id: title.id }
        arguments[:screen] = "living room" if tool == "play_on_screen"
        result, text = call_tool(tool, arguments)
        expect(result["isError"]).to be(true), "#{tool} reached their #{kind}"
        expect(text).to include("No #{kind} has the id")
      end
    end
    expect(WatchState.where(playable: [ their_episode, their_movie ])).to be_empty
    expect(PlaylistItem.where(item: [ their_episode, their_movie ])).to be_empty
    expect(DeviceCommand.count).to eq(0)
  end

  it "holds a kid profile to its ceiling when a title is named by id" do
    first = episode(1)
    Profile.create!(household: household, name: "Juniper", kind: "kid", max_rating_age: 7)

    result, text = call_tool("mark_watched", { kind: "episode", id: first.id, profile: "Juniper" })

    expect(result["isError"]).to be(true)
    expect(text).to include("No episode has the id")
    expect(WatchState.where(playable: first)).to be_empty
  end

  describe "Grid" do
    let!(:station) do
      Station.create!(household: household, number: "4", name: "NBC").tap do |made|
        playing = episode(1)
        coming = episode(2)
        Airing.create!(household: household, station: made, playable: playing, media_file: playing.media_files.first, series_key: show.id,
          starts_at: 10.minutes.ago, ends_at: 40.minutes.from_now, reason: "Test")
        Airing.create!(household: household, station: made, playable: coming, media_file: coming.media_files.first, series_key: show.id,
          starts_at: 40.minutes.from_now, ends_at: 90.minutes.from_now, reason: "Test")
      end
    end

    it "says what's on each channel, now and next" do
      listing = tool_json("whats_on")
      expect(listing.sole).to include("number" => "4", "name" => "NBC")
      expect(listing.sole.dig("on", "title")).to eq("Severance")
      expect(listing.sole.dig("on", "subtitle")).to include("Episode 1")
      expect(listing.sole.dig("next", "subtitle")).to include("Episode 2")

      later = tool_json("whats_on", { channel: "nbc", at: 1.hour.from_now.iso8601 })
      expect(later.sole.dig("on", "subtitle")).to include("Episode 2")
      result, text = call_tool("whats_on", { channel: "ABC" })
      expect(result["isError"]).to be(true)
      expect(text).to eq("No channel is \"ABC\". Channels: 4 NBC.")
    end

    it "puts NBC on in the living room" do
      living_room = screen("Living room")
      tuned = tool_json("tune_channel", { channel: "NBC", screen: "living room" })
      expect(tuned).to include("channel" => "4 NBC", "screen" => "Living room")
      command = living_room.device_commands.sole
      expect(command).to have_attributes(kind: "tune")
      expect(command.payload).to include("number" => "4", "station_id" => station.id, "name" => "NBC")
    end
  end

  it "shows the front door in the living room: a camera by name, live, and what a stream's channel has on" do
    cameras = Library.create!(household: household, name: "Cameras", kind: "live")
    door = LiveStream.create!(household: household, library: cameras, name: "Front door", kind: "camera",
      url: "rtsps://192.168.1.1:7441/AbCdEfGhIjKlMnOp?enableSrtp")
    living_room = screen("Living room")

    expect(tool_json("live_streams").sole).to include("id" => door.id, "name" => "Front door", "kind" => "camera", "status" => "online")
    expect(tool_json("live_streams").to_json).not_to include("AbCdEfGhIjKlMnOp")

    played = tool_json("play_on_screen", { stream: "the front door", screen: "living room" })
    expect(played["playing"]).to include("kind" => "live_stream", "id" => door.id, "title" => "Front door")
    expect(DeviceCommand.sole).to have_attributes(device_id: living_room.id, kind: "play")
    expect(DeviceCommand.sole.payload).to include("kind" => "live_stream", "id" => door.id)

    result, text = call_tool("play_on_screen", { stream: "garage" })
    expect(result["isError"]).to be(true)
    expect(text).to include("There's Front door")

    Station.create!(household: household, number: "50", name: "Door cam", live_stream: door)
    expect(tool_json("whats_on", { channel: "50" }).sole).to include("on" => { "title" => "Front door", "subtitle" => "Live" })

    result, text = call_tool("mark_watched", { kind: "live_stream", id: door.id })
    expect(result["isError"]).to be(true)
    expect(text).to include("nothing to mark watched")
  end
end
