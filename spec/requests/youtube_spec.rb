# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "YouTube settings", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:headers) { auth_headers(admin) }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root, kind: "channels", name: "YouTube") }
  let(:channel_id) { "UCy0tKL1T7wFoYcxCe0xjN6Q" }

  before { allow(Youtube::YtDlp).to receive(:version).and_return("2026.09.20") }

  it "sets the download folder to one of a channels library's folders, and only that" do
    patch "/api/v1/youtube", params: { library_id: library.id, download_root: "/elsewhere" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)

    patch "/api/v1/youtube", params: { library_id: library.id, download_root: root }, headers: headers
    expect(json).to include("yt_dlp_version" => "2026.09.20")
    expect(json["libraries"].sole).to include("download_root" => root)
  end

  it "asks yt-dlp for its version once, not on every visit to Settings" do
    2.times { get "/api/v1/youtube", headers: headers }
    expect(json).to include("yt_dlp_version" => "2026.09.20")
    expect(Youtube::YtDlp).to have_received(:version).once
  end

  it "previews a link, then tracks the channel or queues the video" do
    library.update!(download_root: root)
    allow(Youtube::YtDlp).to receive(:video).with("https://www.youtube.com/watch?v=Ql7w1yX7hbI").and_return(
      "id" => "Ql7w1yX7hbI", "title" => "Dishwashers", "channel" => "Technology Connections", "channel_id" => channel_id
    )

    post "/api/v1/youtube/resolve", params: { url: "https://youtu.be/Ql7w1yX7hbI" }, headers: headers
    expect(json).to include("kind" => "video", "title" => "Dishwashers")
    expect(json["channel"]).to include("title" => "Technology Connections", "tracked" => false)

    post "/api/v1/youtube/track", params: { url: "https://youtu.be/Ql7w1yX7hbI" }, headers: headers
    expect(response).to have_http_status(:created)
    expect(json["queued"]).to eq(1)
    channel = Channel.sole
    expect(channel).to have_attributes(tracked: false, folder: "Technology Connections")

    patch "/api/v1/channels/#{channel.id}/tracking", params: { tracked: true, keep_last: 10, max_height: 720 }, headers: headers
    expect(json).to include("tracked" => true, "keep_last" => 10, "max_height" => 720)
    expect(json["recent"].sole).to include("youtube_id" => "Ql7w1yX7hbI", "state" => "queued")

    patch "/api/v1/channels/#{channel.id}/tracking", params: { title_filter: "full episode" }, headers: headers
    expect(json).to include("title_filter" => "full episode")
    patch "/api/v1/channels/#{channel.id}/tracking", params: { title_filter: "part (" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].join).to include("Title filter isn't a pattern")
    patch "/api/v1/channels/#{channel.id}/tracking", params: { title_filter: "" }, headers: headers
    expect(json["title_filter"]).to be_nil

    post "/api/v1/youtube/resolve", params: { url: "https://vimeo.com/1" }, headers: headers
    expect(json["errors"]).to eq([ "That isn't a YouTube link" ])
  end

  it "turns the end screen off and on for everyone" do
    get "/api/v1/youtube", headers: headers
    expect(json["end_screen"]).to be(true)

    patch "/api/v1/youtube/end_screen", params: { enabled: false }, headers: headers
    expect(json["end_screen"]).to be(false)
    expect(AppSetting.current.youtube_end_screen).to be(false)

    patch "/api/v1/youtube/end_screen", params: { enabled: false }, headers: auth_headers(create_user(household: household))
    expect(response).to have_http_status(:forbidden)
  end

  it "marks a download to keep from the video's page, and hands it back to the keep-last rule", :changes_library_root do
    channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id, keep_last: 1)
    library.update!(download_root: root)
    rows = { "aaaaaaaaaaa" => 2023, "bbbbbbbbbbb" => 2024 }.map do |id, year|
      path = File.join(root, "TC", "#{year} [#{id}].mp4")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "v")
      Video.create!(household: household, library: library, channel: channel, title: id, youtube_id: id, upload_date: Date.new(year),
        source: "info_json")
      YoutubeDownload.create!(household: household, channel: channel, youtube_id: id, state: "done", path: path)
    end
    older = Video.find_by!(youtube_id: "aaaaaaaaaaa")

    get "/api/v1/videos/#{older.id}", headers: headers
    expect(json["retention"]).to eq("download_id" => rows.first.id, "kept" => false, "keep_last" => 1)
    get "/api/v1/videos/#{older.id}", headers: auth_headers(create_user(household: household))
    expect(json["retention"]).to be_nil

    patch "/api/v1/channels/#{channel.id}/tracking/downloads/#{rows.first.id}", params: { kept: true }, headers: headers
    expect(json["recent"].find { |row| row["id"] == rows.first.id }).to include("kept" => true)
    expect(rows.first.reload.kept).to be(true)

    patch "/api/v1/channels/#{channel.id}/tracking/downloads/#{rows.first.id}", params: { kept: false }, headers: headers
    expect(rows.first.reload).to have_attributes(kept: false, state: "removed")
    expect(File).not_to exist(rows.first.path)

    patch "/api/v1/channels/#{channel.id}/tracking/downloads/#{rows.first.id}", params: { kept: true }, headers: headers
    expect(json["errors"]).to eq([ "Only a finished download can be kept" ])
  end

  it "fetches a download again, but not one that's already on its way", :changes_library_root do
    channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id)
    library.update!(download_root: root)
    path = File.join(root, "TC", "2024 [aaaaaaaaaaa].mp4")
    video = Video.create!(household: household, library: library, channel: channel, title: "A", youtube_id: "aaaaaaaaaaa", source: "info_json")
    row = YoutubeDownload.create!(household: household, channel: channel, youtube_id: "aaaaaaaaaaa", state: "done", path: path)

    # No keep-last rule, but there's still a download to fetch again.
    get "/api/v1/videos/#{video.id}", headers: headers
    expect(json["retention"]).to eq("download_id" => row.id, "kept" => false, "keep_last" => nil)

    expect { post "/api/v1/channels/#{channel.id}/tracking/downloads/#{row.id}/retry", headers: headers }
      .to have_enqueued_job(DownloadVideoJob).with(row.id)
    expect(response).to have_http_status(:accepted)
    expect(row.reload).to have_attributes(state: "queued", by_hand: true, path: path, kept: false)

    post "/api/v1/channels/#{channel.id}/tracking/downloads/#{row.id}/retry", headers: headers
    expect(json["errors"]).to eq([ "It's already on its way" ])

    row.update!(state: "removed")
    post "/api/v1/channels/#{channel.id}/tracking/downloads/#{row.id}/retry", headers: headers
    expect(row.reload).to have_attributes(state: "queued", kept: true)
  end

  it "is for admins only" do
    get "/api/v1/youtube", headers: auth_headers(create_user(household: household))
    expect(response).to have_http_status(:forbidden)
  end
end
