# typed: false
# frozen_string_literal: true

require "rails_helper"

# fog:docs/compute-contract.md — fog, as a pool of the machines paired with
# it, is one of Stream's remote transcoders; the machines reach only the
# run-signed /fog/compute/runs.
RSpec.describe "fog-compute/1 surface", type: :request do
  let(:token) { "fog-test-token" }
  let(:hello) do
    { encoder: "videotoolbox", hostname: "fog", platform: "video/videotoolbox", ffmpeg: "9.0.2", worker: "fog-node",
      filters: %w[scale scale_vt zscale tonemap] }
  end

  around do |example|
    previous = ENV["FOG_API_TOKEN"]
    ENV["FOG_API_TOKEN"] = token
    example.run
  ensure
    previous.nil? ? ENV.delete("FOG_API_TOKEN") : ENV["FOG_API_TOKEN"] = previous
  end

  def fog_headers = { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }

  def introduce(pool = "video/videotoolbox")
    post "/fog/compute/transcoders", params: { pool: pool, name: "fog · VideoToolbox", hello: hello }.to_json, headers: fog_headers
    json["id"]
  end

  def poll(id, body = {})
    post "/fog/compute/transcoders/#{id}/poll",
      params: { running: [], exited: [], progress: {}, free: { interactive: 3, batch: 1 }, capacity: { interactive: 4, batch: 2 } }.merge(body).to_json,
      headers: fog_headers
  end

  it "answers only fog" do
    post "/fog/compute/transcoders", params: { pool: "video/videotoolbox" }.to_json,
      headers: { "Authorization" => "Bearer nope", "Content-Type" => "application/json" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "knows a pool as one transcoder, however often fog introduces it" do
    id = introduce
    expect(response).to have_http_status(:ok)
    expect(introduce).to eq(id)
    node = TranscodeNode.find(id)
    expect(node).to have_attributes(fog_pool: "video/videotoolbox", name: "fog · VideoToolbox", encoder: "videotoolbox")
    expect(node.profile.hardware_tonemap?).to be(true)
    expect(introduce("video/vaapi")).not_to eq(id)
  end

  it "takes the pool's room from fog's polls, and is online while fog polls" do
    node = TranscodeNode.find(introduce)
    expect(node.online?).to be(false)
    poll(node.id)
    expect(response).to have_http_status(:ok)
    expect(json).to include("start" => [], "stop" => [], "poll_ms" => 250)
    node.reload
    expect(node).to have_attributes(max_sessions: 4, online?: true)
    expect(node.fog_free("interactive")).to eq(3)
    expect(node.fog_free("batch")).to eq(1)
    expect(Playback::Placement.node_for_video).to eq(node)

    poll(node.id, free: { interactive: 0, batch: 0 })
    expect(Playback::Placement.node_for_video).to be_nil
  end

  context "with a run handed to it" do
    let(:household) { create_household }
    let(:file) do
      root = build_root("h264_aac.mp4" => "h264_aac.mp4")
      library = create_library(household: household, roots: root)
      path = File.join(root, "h264_aac.mp4")
      MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    end
    let(:session) do
      movie = Movie.create!(household: household, library: file.library, title: "T")
      PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file,
        method: "video_transcode", decision: {}, started_at: Time.current, last_seen_at: Time.current)
    end

    it "hands it out with its class, outputs and a signed upload address, through fog's route" do
      node = TranscodeNode.find(introduce)
      handle = Playback::Runner.start_remote(node, session: session) { |source| [ "ffmpeg", *source.args, "{out}/index.m3u8" ] }
      run = TranscodeRun.find(handle.run_id)
      run_token = Playback::RunToken.issue(run)
      expect(run.argv).to include("{server}/fog/compute/runs/#{run_token}/source")

      poll(node.id)
      start = json["start"].sole
      expect(start).to include("id" => run.id, "kind" => "session", "class" => "interactive",
        "outputs" => { "init" => [ "init.mp4" ], "stream" => "gop-*.m4s" },
        "upload" => "{server}/fog/compute/runs/#{run_token}/files/{name}")

      # The machine reads the original by the run token alone…
      get "/fog/compute/runs/#{run_token}/source"
      expect(response).to have_http_status(:ok)
      get "/fog/compute/runs/nonsense/source"
      expect(response).to have_http_status(:not_found)

      # …and uploads the same way.
      allow(Playback::NodeLink).to receive(:store).and_return(true)
      put "/fog/compute/runs/#{run_token}/files/gop-0.m4s", params: "bytes", headers: { "Content-Type" => "application/octet-stream" }
      expect(response).to have_http_status(:no_content)
      expect(Playback::NodeLink).to have_received(:store).with(run, "gop-0.m4s", anything, size: 5)

      # A run fog reports ended is over, and its address stops working.
      poll(node.id, running: [], exited: [ { id: run.id, status: nil, log: "fog: the machine running it went offline" } ])
      expect(run.reload.state_enum).to eq(TranscodeRun::State::Exited)
      get "/fog/compute/runs/#{run_token}/source"
      expect(response).to have_http_status(:not_found)
    end
  end

  it "forgets the transcoder when fog takes the pool away" do
    id = introduce
    delete "/fog/compute/transcoders/#{id}", headers: fog_headers
    expect(response).to have_http_status(:no_content)
    expect(TranscodeNode.exists?(id)).to be(false)
    poll(id)
    expect(response).to have_http_status(:not_found)
  end

  it "keeps fog's room out of an admin's hands" do
    node = TranscodeNode.find(introduce)
    admin = create_user(household: create_household, role: "admin")
    patch "/api/v1/transcode_nodes/#{node.id}", params: { max_sessions: 2 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
  end
end
