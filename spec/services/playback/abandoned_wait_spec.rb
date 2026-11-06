# typed: false
# frozen_string_literal: true

require "rails_helper"
require "puma"
require "puma/server"
require "socket"

# A player that seeks drops the segment it was fetching. Through a real
# Puma: the request waiting on the transcoder notices its client has hung
# up (Playback::ClientGone) and gives its thread back, instead of holding
# it — and asking the transcoder again for somewhere nobody is — for the
# twenty seconds a segment is waited for.
RSpec.describe "A segment request the player dropped" do
  before do
    require_ffprobe!
    WebMock.disable_net_connect!(allow_localhost: true)
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    # No transcoder: nothing asked for is ever made.
    @asked = []
    allow(Playback::Signal).to receive(:request) { |_session, gop, _variant = 0, resent: false| @asked << [ gop, resent ] }
    # One thread: a request still waiting keeps the next one out.
    @server = Puma::Server.new(Rails.application, nil, min_threads: 1, max_threads: 1, log_writer: Puma::LogWriter.null)
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run
  end

  after do
    @server&.stop(true)
    WebMock.disable_net_connect!(allow_localhost: false)
    FileUtils.rm_rf(@cache)
  end

  let(:household) { Household.create!(name: "Stream") }
  let(:session) do
    root = build_root("Heat/Heat.mkv" => "h264_aac_ac3_subs.mkv")
    library = create_library(household: household, roots: root)
    path = File.join(root, "Heat/Heat.mkv")
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    Media::KeyframeIndex.store(file.reload, [ 0 ], Media::KeyframeIndex::Source::Packets)
    caps = Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac])
    decision = Playback::Decision.new(file, caps)
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: Movie.create!(household: household, library: library, title: "Heat"),
      media_file: file.reload, method: decision.method.serialize, decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current)
  end

  it "stops waiting when its client hangs up, and frees its thread for the next request" do
    token = Playback::StreamToken.issue(session)
    dropped = TCPSocket.new("127.0.0.1", @port)
    dropped.write("GET /media/s/#{token}/hls/seg-0.m4s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    Timeout.timeout(5) { sleep 0.02 until @asked.any? }
    dropped.close

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = Net::HTTP.start("127.0.0.1", @port, read_timeout: 10) { |http| http.get("/up") }
    expect(response.code).to eq("200")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    # Nobody to tell, and nothing went wrong: no error is recorded for it.
    expect(PlaybackEvent.where(playback_session: session, kind: "error")).to be_empty
    # And it has stopped asking the transcoder.
    asked = @asked.size
    sleep 2.5
    expect(@asked.size).to eq(asked)
  end
end
