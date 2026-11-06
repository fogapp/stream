# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Subscriptions and Watch later", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }
  let(:profile) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }

  def channel(title) = Channel.create!(household: household, library: library, folder: title, title: title)

  def video(channel, title, uploaded)
    Video.create!(household: household, library: library, channel: channel, title: title, upload_date: uploaded, source: "folder").tap do |video|
      file = MediaFile.create!(household: household, library: library, path: "/v/#{title}.mkv", size: 1, mtime: Time.current, state: "probed",
        duration_seconds: 600)
      video.editions.create!(media_file: file)
    end
  end

  it "gives each profile a feed of its channels' videos, newest first, and a home row of what it hasn't seen" do
    tc = channel("Technology Connections")
    other = channel("Someone else")
    video(tc, "Toasters", Date.new(2020, 1, 1))
    dishwashers = video(tc, "Dishwashers", Date.new(2024, 1, 1))
    video(other, "Not followed", Date.new(2025, 1, 1))
    profile

    post "/api/v1/channels/#{tc.id}/subscription", headers: headers
    get "/api/v1/subscriptions", headers: headers
    expect(json["channels"].map { |c| c["title"] }).to eq([ "Technology Connections" ])
    expect(json["videos"].map { |v| v["title"] }).to eq(%w[Dishwashers Toasters])

    Playback::Progress.mark(profile, dishwashers, watched: true)
    get "/api/v1/home", headers: headers
    row = json["hubs"].find { |hub| hub["key"] == "subscriptions" }
    expect(row["items"].map { |v| v["title"] }).to eq(%w[Toasters])

    get "/api/v1/channels/#{tc.id}", headers: headers
    expect(json["subscribed"]).to be(true)
    delete "/api/v1/channels/#{tc.id}/subscription", headers: headers
    get "/api/v1/subscriptions", headers: headers
    expect(json["videos"]).to eq([])
  end

  it "saves to Watch later, which every profile has, can't be deleted, and lets go of what's been watched" do
    tc = channel("TC")
    saved = video(tc, "Dishwashers", Date.new(2024, 1, 1))
    profile

    post "/api/v1/watch_later", params: { item_type: "video", item_id: saved.id }, headers: headers
    playlist_id = json["playlist_id"]
    get "/api/v1/watch_later", headers: headers
    expect(json["items"]).to eq([ "video:#{saved.id}" ])

    get "/api/v1/playlists", headers: headers
    expect(json.first).to include("title" => "Watch later", "watch_later" => true, "item_count" => 1)
    delete "/api/v1/playlists/#{playlist_id}", headers: headers
    expect(response).to have_http_status(:unprocessable_content)

    session = PlaybackSession.create!(household: household, profile: profile, playable: saved, media_file: saved.media_files.first, method: "direct",
      decision: {}, device_name: "x", started_at: Time.current, last_seen_at: Time.current)
    Playback::Progress.report(session, position: 599.0)
    get "/api/v1/watch_later", headers: headers
    expect(json["items"]).to eq([])
  end
end
