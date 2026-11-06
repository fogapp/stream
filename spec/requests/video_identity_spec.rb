# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Saying which YouTube video a video is", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }
  let(:channel) { Channel.create!(household: household, library: library, folder: "Funhaus", title: "Funhaus") }
  let(:candidates) do
    [ { "youtube_id" => "ggggggggggg", "title" => "STAR WARS JESUS - Demo Disk Gameplay", "duration_seconds" => 845.0, "score" => 0.71,
        "reasons" => [ "title 80% alike", "length differs by 145s" ] } ]
  end
  let(:video) do
    Video.create!(household: household, library: library, channel: channel, title: "STAR WARS PORNO", source: "folder",
      identity: "needs_review", youtube_candidates: candidates)
  end

  it "shows the candidates to pick from, and takes a pick or a pasted link" do
    get "/api/v1/videos/#{video.id}", headers: auth_headers(admin)
    expect(json).to include("identity" => "needs_review", "youtube_candidates" => candidates)

    post "/api/v1/videos/#{video.id}/identify", params: { youtube_id: "ggggggggggg" }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:accepted)
    expect(video.reload).to have_attributes(youtube_id: "ggggggggggg", identity: "identified", youtube_candidates: [])
    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("HydrateVideoJob")

    get "/api/v1/videos/#{video.id}", headers: auth_headers(admin)
    expect(json).to include("identity" => "identified", "youtube_candidates" => [])

    post "/api/v1/videos/#{video.id}/identify", params: { url: "https://youtu.be/hhhhhhhhhhh?t=3" }, headers: auth_headers(admin), as: :json
    expect(video.reload).to have_attributes(youtube_id: "hhhhhhhhhhh", url: "https://www.youtube.com/watch?v=hhhhhhhhhhh")

    # A fetch that failed is asked again from the file page's checklist.
    file = MediaFile.create!(household: household, library: library, path: "/v/porno.mp4", size: 1, mtime: Time.current, state: "probed")
    video.editions.create!(media_file: file)
    clear_enqueued_jobs
    post "/api/v1/media_files/#{file.id}/rerun", params: { step: "youtube_details" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:accepted)
    expect(HydrateVideoJob).to have_been_enqueued.with(video.id)
  end

  it "refuses a link that isn't one video, and a video another file already is" do
    other = Video.create!(household: household, library: library, channel: channel, title: "Jesus", source: "youtube",
      youtube_id: "ggggggggggg", identity: "identified")

    post "/api/v1/videos/#{video.id}/identify", params: { url: "https://vimeo.com/123" }, headers: auth_headers(admin), as: :json
    expect(json).to eq("errors" => [ "That isn't a YouTube link" ])
    post "/api/v1/videos/#{video.id}/identify", params: { url: "youtube.com/@Funhaus" }, headers: auth_headers(admin), as: :json
    expect(json).to eq("errors" => [ "Paste the link to one video" ])
    post "/api/v1/videos/#{video.id}/identify", params: { youtube_id: "ggggggggggg" }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:conflict)
    expect(json).to eq("errors" => [ "#{other.title} is already that video" ])
    expect(video.reload.youtube_id).to be_nil
  end

  it "lets an admin say it isn't on YouTube, and no one else" do
    post "/api/v1/videos/#{video.id}/not_on_youtube", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/videos/#{video.id}/identify", params: { youtube_id: "ggggggggggg" }, headers: auth_headers(member), as: :json
    expect(response).to have_http_status(:forbidden)

    post "/api/v1/videos/#{video.id}/not_on_youtube", headers: auth_headers(admin)
    expect(response).to have_http_status(:no_content)
    get "/api/v1/videos/#{video.id}", headers: auth_headers(admin)
    expect(json).to include("identity" => "not_on_youtube", "youtube_candidates" => [])
  end
end
