# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Channels", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }
  let(:profile) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }
  let(:channel) { Channel.create!(household: household, library: library, folder: "TC", title: "Technology Connections", handle: "@tc") }

  def video(title, uploaded, description: nil, state: "probed")
    Video.create!(household: household, library: library, channel: channel, title: title, upload_date: uploaded, source: "info_json",
      description: description).tap do |video|
      file = MediaFile.create!(household: household, library: library, path: "/v/#{title}.mkv", size: 1, mtime: Time.current, state: state,
        duration_seconds: 600)
      video.editions.create!(media_file: file)
    end
  end

  it "lists channels with counts, and a channel's videos newest first" do
    old = video("Toasters", Date.new(2020, 1, 1))
    video("Dishwashers", Date.new(2024, 1, 1))
    video("Broken", Date.new(2025, 1, 1), state: "broken")
    Playback::Progress.mark(profile, old, watched: true)

    get "/api/v1/channels", params: { library_id: library.id }, headers: headers
    expect(json.sole).to include("title" => "Technology Connections", "video_count" => 2, "unwatched_count" => 1, "latest_upload" => "2024-01-01")

    get "/api/v1/channels/#{channel.id}", headers: headers
    expect(json["videos"].map { |v| [ v["title"], v["watched"], v["duration_seconds"] ] }).to eq([ [ "Dishwashers", false, 600.0 ], [ "Toasters", true, 600.0 ] ])

    get "/api/v1/channels/#{channel.id}", params: { unwatched: true }, headers: headers
    expect(json["videos"].map { |v| v["title"] }).to eq([ "Dishwashers" ])
  end

  it "shows a video's page with chapters from its description and more from the channel" do
    main = video("Dishwashers", Date.new(2024, 1, 1), description: "0:00 Hi\n1:00 Soap\n2:00 Bye")
    video("Toasters", Date.new(2020, 1, 1))

    get "/api/v1/videos/#{main.id}", headers: headers

    expect(json).to include("title" => "Dishwashers", "playable" => true, "channel" => include("title" => "Technology Connections"))
    expect(json["chapters"].map { |c| c["title"] }).to eq(%w[Hi Soap Bye])
    expect(json["more_from_channel"].map { |v| v["title"] }).to eq([ "Toasters" ])
  end

  it "puts what the profile hasn't finished ahead of what it has in more from the channel" do
    main = video("Dishwashers", Date.new(2024, 1, 1))
    video("Toasters", Date.new(2020, 1, 1))
    watched = video("Heat pumps", Date.new(2023, 1, 1))
    started = video("Microwaves", Date.new(2019, 1, 1))
    Playback::Progress.mark(profile, watched, watched: true)
    WatchState.create!(profile: profile, playable: started, position_seconds: 30)

    get "/api/v1/videos/#{main.id}", headers: headers

    expect(json["more_from_channel"].map { |v| [ v["title"], v["watched"] ] })
      .to eq([ [ "Toasters", false ], [ "Microwaves", false ], [ "Heat pumps", true ] ])
  end

  it "finds channels and videos in search, and puts new videos on the home screen" do
    video("Dishwashers", Date.new(2024, 1, 1))

    get "/api/v1/search", params: { q: "technology" }, headers: headers
    expect(json["channels"].map { |c| c["title"] }).to eq([ "Technology Connections" ])
    get "/api/v1/search", params: { q: "dishwash" }, headers: headers
    expect(json["videos"].map { |v| v["title"] }).to eq([ "Dishwashers" ])

    get "/api/v1/home", headers: headers
    hub = json["hubs"].find { |h| h["title"] == "New in YouTube" }
    expect(hub).to include("kind" => "videos")
    expect(hub["items"].map { |v| v["title"] }).to eq([ "Dishwashers" ])
  end
end
