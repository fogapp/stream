# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Grid presets", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:library) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def show(title, genres:, networks:, rating:, episodes: 6, minutes: 22)
    Show.create!(household: household, library: library, folder: title, title: title, genres: genres, networks: networks,
      vote_average: rating).tap do |series|
      season = series.seasons.create!(season_number: 1)
      episodes.times do |index|
        file = MediaFile.create!(household: household, library: library, path: "/tv/#{title}/#{index}.mkv", size: 1, mtime: Time.current,
          state: "probed", duration_seconds: minutes * 60.0)
        series.episodes.create!(season: season, season_number: 1, episode_number: index + 1).editions.create!(media_file: file)
      end
    end
  end

  it "makes a broadcaster's week from its own shows: its best comedies at 8, dramas from 9" do
    show("The Office", genres: %w[Comedy], networks: %w[NBC], rating: 8.6)
    show("Parks and Recreation", genres: %w[Comedy], networks: %w[NBC], rating: 8.1)
    show("30 Rock", genres: %w[Comedy], networks: %w[NBC], rating: 7.9)
    show("ER", genres: %w[Drama], networks: %w[NBC], rating: 8.0, minutes: 44)
    show("Friends", genres: %w[Comedy], networks: %w[NBC], rating: 8.5, episodes: 2)
    show("The Sopranos", genres: %w[Drama Crime], networks: %w[HBO], rating: 9.0, minutes: 55)

    get "/api/v1/stations/preset", params: { kind: "network", value: "NBC" }, headers: auth_headers(admin)
    expect(json).to include("number" => "4", "name" => "NBC", "call_sign" => "NBC", "snap_minutes" => 30)
    appointments = json["blocks"].select { |block| block["layer"] == "appointment" }
    # Friends has too few episodes to hold a weekly slot.
    expect(appointments.map { |block| [ block["name"], block["days"], block["start_minute"] ] }).to eq([
      [ "The Office", 1, 1200 ], [ "Parks and Recreation", 1, 1230 ], [ "ER", 1, 1260 ], [ "30 Rock", 2, 1200 ]
    ])
    expect(json["blocks"].map { |block| block["name"] }).to include("Morning reruns", "Late night")
    expect(json["blocks"].first).to include("layer" => "base", "source" => { "networks" => [ "NBC" ], "kinds" => [ "episode" ] })

    # The draft is an ordinary channel.
    post "/api/v1/stations", params: json.slice("number", "name", "call_sign", "snap_minutes", "blocks"), headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:created)
    station = Station.find(json["id"])
    office = station.airings.joins("JOIN episodes ON episodes.id = airings.playable_id").where(episodes: { show_id: Show.find_by(title: "The Office").id })
    expect(office).to exist
    expect(station.airings.where(playable_type: "Episode", playable_id: Show.find_by(title: "The Sopranos").episodes.select(:id))).to be_empty

    get "/api/v1/stations/preset", params: { kind: "network", value: "NBC" }, headers: auth_headers(admin)
    expect(json["number"]).to eq("5")
  end

  it "makes a premium channel of films on the hour and Sunday originals" do
    show("The Sopranos", genres: %w[Drama Crime], networks: %w[HBO], rating: 9.0, minutes: 55)
    get "/api/v1/stations/preset", params: { kind: "network", value: "HBO" }, headers: auth_headers(admin)
    expect(json).to include("number" => "501", "snap_minutes" => 60)
    expect(json["blocks"].map { |block| [ block["layer"], block["name"], block["days"], block["start_minute"] ] })
      .to eq([ [ "base", nil, 127, nil ], [ "appointment", "The Sopranos", 64, 1260 ] ])
  end

  it "makes the others, and refuses a kind it doesn't know" do
    %w[kids sitcoms].each do |kind|
      get "/api/v1/stations/preset", params: { kind: kind }, headers: auth_headers(admin)
      expect(json["blocks"]).not_to be_empty
    end
    get "/api/v1/stations/preset", params: { kind: "decade", value: "1990" }, headers: auth_headers(admin)
    expect(json).to include("name" => "The 90s", "number" => "90")
    expect(json["blocks"].first["source"]).to include("year_from" => 1990, "year_to" => 1999)
    get "/api/v1/stations/preset", params: { kind: "holiday", value: "christmas" }, headers: auth_headers(admin)
    expect(json["blocks"].last).to include("layer" => "special", "name" => "Christmas")
    expect(json["blocks"].last["starts_on"]).to end_with("-12-01")
    get "/api/v1/stations/preset", params: { kind: "movies", value: "Horror" }, headers: auth_headers(admin)
    expect(json).to include("name" => "Horror movies")
    get "/api/v1/stations/preset", params: { kind: "youtube" }, headers: auth_headers(admin)
    expect(json).to include("name" => "YouTube", "snap_minutes" => 0)
    expect(json["blocks"].sole["source"]).to eq("kinds" => [ "video" ], "unwatched" => true)
    get "/api/v1/stations/preset", params: { kind: "weather" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
  end
end
