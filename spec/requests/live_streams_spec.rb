# typed: false
# frozen_string_literal: true

require "rails_helper"

# A live library's streams (PROPOSAL §7.8): an address saves only once it has
# been read, and never comes back out.
RSpec.describe "Live streams", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:token) { "AbCdEfGhIjKlMnOp" }
  let(:url) { "rtsps://192.168.1.1:7441/#{token}?enableSrtp" }
  let(:camera) do
    LiveStreams::Prober::Result.new(container: "rtsp", streams: Media::Probe.streams_from("streams" => [
      { "index" => 0, "codec_type" => "audio", "codec_name" => "aac", "channels" => 1 },
      { "index" => 1, "codec_type" => "video", "codec_name" => "h264", "width" => 3840, "height" => 2160, "pix_fmt" => "yuv420p",
        "avg_frame_rate" => "24/1" }
    ]))
  end

  def params_for(**overrides)
    { live_stream: { name: "Front door", library_id: library.id, kind: "camera", url: url, trust_certificate: true }.merge(overrides) }
  end

  it "adds a camera once it has been read, and never sends the address back" do
    allow(LiveStreams::Prober).to receive(:probe).and_return(camera)
    allow(ToolRunner).to receive(:version).and_return("ffprobe version 7.1.4")

    post "/api/v1/live_streams", params: params_for, headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:created)
    expect(json).to include("name" => "Front door", "kind" => "camera", "source" => "rtsps://192.168.1.1:7441",
      "status" => "online", "trust_certificate" => true)
    expect(json["tracks"].map { |track| track["codec"] }).to eq(%w[aac h264])
    expect(response.body).not_to include(token)
    stream = LiveStream.sole
    expect(stream.url).to eq(url)
    expect(stream.analysis_runs.sole.status).to eq("succeeded")

    get "/api/v1/live_streams", headers: auth_headers(admin)
    get "/api/v1/live_streams/#{stream.id}", headers: auth_headers(member)
    expect(response.body).not_to include(token)
    expect(json).not_to have_key("trust_certificate")
  end

  it "doesn't keep an address it couldn't read" do
    allow(LiveStreams::Prober).to receive(:probe).and_raise(LiveStreams::Prober::Failure, "Nothing answered at rtsps://192.168.1.1:7441")

    post "/api/v1/live_streams", params: params_for, headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to eq([ "Nothing answered at rtsps://192.168.1.1:7441" ])
    expect(LiveStream.count).to eq(0)
  end

  it "re-reads a stream only when how it's read changes, and keeps the address when none is sent" do
    allow(ToolRunner).to receive(:version).and_return("ffprobe version 7.1.4")
    allow(LiveStreams::Prober).to receive(:probe).and_return(camera)
    post "/api/v1/live_streams", params: params_for, headers: auth_headers(admin), as: :json
    stream = LiveStream.sole

    patch "/api/v1/live_streams/#{stream.id}", params: params_for(name: "Porch", url: ""), headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:ok)
    expect(LiveStreams::Prober).to have_received(:probe).once
    expect(stream.reload).to have_attributes(name: "Porch", url: url)

    patch "/api/v1/live_streams/#{stream.id}", params: params_for(url: "rtsp://192.168.1.1:7447/#{token}"), headers: auth_headers(admin), as: :json
    expect(LiveStreams::Prober).to have_received(:probe).twice
  end

  it "tests an address as typed, or a saved one with a change" do
    allow(LiveStreams::Prober).to receive(:probe).and_return(camera)

    post "/api/v1/live_streams/test", params: params_for, headers: auth_headers(admin), as: :json
    expect(json).to include("ok" => true, "message" => "Found H.264 2160p 24 fps with 1 audio track")

    stream = LiveStream.create!(household: household, library: library, name: "Door", kind: "camera", url: url)
    allow(LiveStreams::Prober).to receive(:probe) do |candidate|
      expect(candidate.url).to eq(url)
      expect(candidate.trust_certificate).to be(true)
      raise LiveStreams::Prober::Failure, "rtsps://192.168.1.1:7441 didn't send a stream in time"
    end
    post "/api/v1/live_streams/test", params: params_for(url: "").merge(id: stream.id), headers: auth_headers(admin), as: :json
    expect(json).to eq("ok" => false, "message" => "rtsps://192.168.1.1:7441 didn't send a stream in time")
    expect(stream.reload.trust_certificate).to be(false)
  end

  it "is for admins to change" do
    stream = LiveStream.create!(household: household, library: library, name: "Door", kind: "camera", url: url)

    post "/api/v1/live_streams", params: params_for, headers: auth_headers(member), as: :json
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/live_streams/test", params: params_for, headers: auth_headers(member), as: :json
    expect(response).to have_http_status(:forbidden)
    delete "/api/v1/live_streams/#{stream.id}", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end

  it "shows a profile only the streams it may see" do
    other = Library.create!(household: household, name: "Web", kind: "live")
    LiveStream.create!(household: household, library: library, name: "Door", kind: "camera", url: url)
    LiveStream.create!(household: household, library: other, name: "News", kind: "web", url: "https://example.com/n.m3u8", content_rating: "TV-14")
    kid = Profile.create!(household: household, name: "Kid", library_ids: [ library.id, other.id ], max_rating_age: 10, allow_unrated: true)
    cameras_only = Profile.create!(household: household, name: "Cams", library_ids: [ library.id ])

    get "/api/v1/live_streams", headers: auth_headers(member).merge(profile_header(kid))
    expect(json.map { |row| row["name"] }).to eq([ "Door" ])
    get "/api/v1/live_streams?library_id=#{other.id}", headers: auth_headers(member).merge(profile_header(cameras_only))
    expect(json).to eq([])
    get "/api/v1/live_streams/#{LiveStream.find_by!(name: 'News').id}", headers: auth_headers(member).merge(profile_header(kid))
    expect(response).to have_http_status(:not_found)
  end
end
