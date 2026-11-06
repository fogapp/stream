# typed: false
# frozen_string_literal: true

require "rails_helper"

# Pressing play on a live stream (PROPOSAL §7.8): a session without a file,
# the relay asked for at once, and its playlist and segments served under
# the session's token — never the stream's address.
RSpec.describe "Live stream playback", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:token) { "AbCdEfGhIjKlMnOp" }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera", trust_certificate: true,
      url: "rtsps://192.168.1.1:7441/#{token}?enableSrtp").tap do |live|
      live.media_streams.create!(index: 0, kind: "audio", codec: "aac", channels: 1)
      live.media_streams.create!(index: 1, kind: "video", codec: "h264", bit_depth: 8, width: 3840, height: 2160)
    end
  end
  let(:capabilities) { { hls: "mse", containers: %w[mp4], video: %w[h264], audio: %w[aac], max_height: 1080 } }

  around do |example|
    Dir.mktmpdir("stream-cache") do |cache|
      @cache = cache
      example.run
    end
  end

  before { stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache)) }

  def play(as: user)
    post "/api/v1/playback_sessions", params: { playable_type: "live_stream", playable_id: stream.id, capabilities: capabilities },
      headers: auth_headers(as), as: :json
  end

  it "starts a session that relays the camera, and asks for the relay at once" do
    notified = []
    allow(Playback::Signal).to receive(:relay) { |id| notified << id }

    play

    expect(response).to have_http_status(:created)
    expect(json).to include("method" => "remux", "title" => "Front door", "subtitle" => "Camera", "back_path" => "/library/#{library.id}",
      "duration_seconds" => nil, "media_file" => nil, "next_up" => nil)
    expect(json["live_stream"]).to include("id" => stream.id, "kind" => "camera")
    expect(json["source"]).to include("kind" => "hls", "url" => %r{\A/media/s/[^/]+/live/index\.m3u8\z})
    expect(response.body).not_to include(token)
    session = PlaybackSession.find(json["id"])
    expect(session).to have_attributes(media_file_id: nil, playable: stream)
    expect(notified).to eq([ session.id ])
    expect(Playback::LiveCache.wanted_at(Playback::LiveCache.key_for(session))).to be_within(5).of(Time.current)
  end

  it "reads a team's MLB.tv stream the first time it plays, and goes back to Baseball" do
    allow(Playback::Signal).to receive(:relay)
    team = Mlb::TeamStreams.for(household.id, 114, "Cleveland Guardians")
    allow(LiveStreams::Prober).to receive(:call) do |live|
      live.media_streams.create!(index: 0, kind: "video", codec: "h264", bit_depth: 8, width: 1920, height: 1080)
      live.media_streams.create!(index: 1, kind: "audio", codec: "aac", channels: 2)
      live.update!(probed_at: Time.current)
    end

    post "/api/v1/playback_sessions", params: { playable_type: "live_stream", playable_id: team.id, capabilities: capabilities },
      headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:created)
    expect(json).to include("title" => "Cleveland Guardians", "subtitle" => "MLB.tv", "back_path" => "/baseball")

    post "/api/v1/playback_sessions", params: { playable_type: "live_stream", playable_id: team.id, capabilities: capabilities },
      headers: auth_headers(user), as: :json
    expect(LiveStreams::Prober).to have_received(:call).once
  end

  it "says why a team's stream won't play" do
    team = Mlb::TeamStreams.for(household.id, 114, "Cleveland Guardians")
    allow(LiveStreams::Prober).to receive(:call).and_raise(LiveStreams::Prober::Failure, "The Cleveland Guardians aren't playing on MLB.tv right now")

    post "/api/v1/playback_sessions", params: { playable_type: "live_stream", playable_id: team.id, capabilities: capabilities },
      headers: auth_headers(user), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to eq([ "The Cleveland Guardians aren't playing on MLB.tv right now" ])
  end

  it "plays a YouTube stream like any other, saying it is one" do
    allow(Playback::Signal).to receive(:relay)
    stream.update!(kind: "youtube", url: "https://youtu.be/rFZHOHl-L8A")

    play

    expect(response).to have_http_status(:created)
    expect(json).to include("title" => "Front door", "subtitle" => "YouTube")
    expect(json["live_stream"]).to include("kind" => "youtube")
  end

  it "serves the relay's playlist once it has a segment, and its files by the names it gives them" do
    allow(Playback::Signal).to receive(:relay)
    play
    base = json.dig("source", "url").delete_suffix("/index.m3u8")
    key = Playback::LiveCache.key_for(PlaybackSession.find(json["id"]))
    directory = Playback::LiveCache.directory(key)
    FileUtils.mkdir_p(directory)
    File.write(directory.join("index.m3u8"), "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:5.0,\nseg-1791000000.m4s\n")
    File.write(directory.join("init.mp4"), "init")
    File.write(directory.join("seg-1791000000.m4s"), "segment")
    File.write(directory.join("ffmpeg.log"), "secrets")

    get "#{base}/index.m3u8"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/vnd.apple.mpegurl")
    expect(response.body).to include("seg-1791000000.m4s")
    expect(Playback::Signal).to have_received(:relay).twice

    get "#{base}/seg-1791000000.m4s"
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("segment")
    get "#{base}/init.mp4"
    expect(response.headers["Cache-Control"]).to eq("no-cache")
    get "#{base}/ffmpeg.log"
    expect(response).to have_http_status(:not_found)
    # What a file's session serves isn't a live stream's.
    session_base = base.delete_suffix("/live")
    %w[hls/index.m3u8 hls/init.mp4 hls/seg-0.m4s subtitles/s0.vtt fonts/a.ttf].each do |path|
      get "#{session_base}/#{path}"
      expect(response).to have_http_status(:not_found), path
    end
  end

  it "says why a relay that couldn't start, after waiting for it" do
    allow(Playback::Signal).to receive(:relay)
    stub_const("MediaController::LIVE_WAIT", 0.3)
    play
    key = Playback::LiveCache.key_for(PlaybackSession.find(json["id"]))
    Playback::LiveCache.write_status(key, "reconnecting", "Nothing answered at rtsps://192.168.1.1:7441")

    get json.dig("source", "url")
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to eq("Nothing answered at rtsps://192.168.1.1:7441")
  end

  it "keeps the session open without watch state, and tells the player how the relay is going" do
    allow(Playback::Signal).to receive(:relay)
    play
    session = PlaybackSession.find(json["id"])
    Playback::LiveCache.write_status(Playback::LiveCache.key_for(session), "reconnecting", "The stream stopped sending")

    post "#{json['progress_url']}", params: { position: 42.0 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(json).to include("relay" => { "state" => "reconnecting", "message" => "The stream stopped sending" })
    expect(WatchState.count).to eq(0)
    expect(session.reload.position_seconds).to eq(42.0)
  end

  it "shows on the Playback page and in the stats like any play" do
    allow(Playback::Signal).to receive(:relay)
    admin = create_user(household: household, role: "admin")
    play(as: admin)
    id = json["id"]

    get "/api/v1/playback_decisions", headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Front door")
    get "/api/v1/playback_decisions/#{id}", headers: auth_headers(admin)
    expect(json).to include("title" => "Front door", "media_file" => nil)
    expect(response.body).not_to include(token)
    %w[now_playing summary history].each do |page|
      get "/api/v1/stats/#{page}", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok), page
    end
  end

  it "isn't playable by a profile that may not see it" do
    kid = Profile.create!(household: household, name: "Kid", library_ids: [ create_library(household: household, roots: build_root).id ])
    post "/api/v1/playback_sessions", params: { playable_type: "live_stream", playable_id: stream.id },
      headers: auth_headers(user).merge(profile_header(kid)), as: :json
    expect(response).to have_http_status(:not_found)
  end
end
