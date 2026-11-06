# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "A channels library's video feed", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }
  let(:profile) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }

  def channel(title, in_library: library) = Channel.create!(household: household, library: in_library, folder: title, title: title)

  def video(channel, title, uploaded)
    Video.create!(household: household, library: channel.library, channel: channel, title: title, upload_date: uploaded, source: "folder").tap do |video|
      file = MediaFile.create!(household: household, library: channel.library, path: "/v/#{title}.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 600)
      video.editions.create!(media_file: file)
    end
  end

  it "lists every channel's videos newest first, or one channel's, and can leave out what's been watched" do
    tc = channel("Technology Connections")
    other = channel("Someone else")
    elsewhere = channel("Another library", in_library: create_library(household: household, roots: build_root, kind: "channels", name: "More"))
    video(tc, "Toasters", Date.new(2020, 1, 1))
    dishwashers = video(tc, "Dishwashers", Date.new(2024, 1, 1))
    video(other, "Rivers", Date.new(2022, 1, 1))
    video(elsewhere, "Not this library", Date.new(2025, 1, 1))

    get "/api/v1/videos", params: { library_id: library.id }, headers: headers
    expect(json.map { |v| v["title"] }).to eq(%w[Dishwashers Rivers Toasters])
    expect(json.first["channel"]).to include("id" => tc.id, "title" => "Technology Connections")

    get "/api/v1/videos", params: { library_id: library.id, channel_id: tc.id }, headers: headers
    expect(json.map { |v| v["title"] }).to eq(%w[Dishwashers Toasters])

    Playback::Progress.mark(profile, dishwashers, watched: true)
    get "/api/v1/videos", params: { library_id: library.id, unwatched: true }, headers: headers
    expect(json.map { |v| v["title"] }).to eq(%w[Rivers Toasters])

    get "/api/v1/videos", params: { library_id: library.id, per: 1, page: 2 }, headers: headers
    expect(json.map { |v| v["title"] }).to eq(%w[Rivers])
  end
end
