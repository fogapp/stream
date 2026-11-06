# typed: false
# frozen_string_literal: true

require "rails_helper"

# The relay's ffmpeg (PROPOSAL §7.8, CLAUDE.md invariant 6).
RSpec.describe Playback::LiveArgs do
  include ActiveSupport::Testing::TimeHelpers

  let(:profile) { Playback::Encoders::Profile.new(kind: Playback::Encoders::Kind::Software, tonemap_filter: nil) }
  let(:directory) { Pathname.new("/cache/live/key") }
  let(:camera) do
    LiveStream.new(name: "Door", kind: "camera", url: "rtsps://192.168.1.1:7441/AbCdEfGhIjKlMnOp?enableSrtp", trust_certificate: true).tap do |live|
      live.media_streams.build(index: 0, kind: "audio", codec: "aac", channels: 1)
      live.media_streams.build(index: 1, kind: "audio", codec: "opus", channels: 2)
      live.media_streams.build(index: 2, kind: "video", codec: "h264", height: 2160)
    end
  end
  let(:copy) { { "video" => { "index" => 2, "copy" => true, "codec" => "h264" }, "audio" => { "index" => 1, "copy" => true, "codec" => "opus" } } }

  def pairs(argv) = argv.each_cons(2).to_a

  before { allow(Playback::FfmpegArgs::Input).to receive(:rtsp_tls_verify?).and_return(true) }

  it "asks the build whether its RTSP demuxer takes -tls_verify, and leaves it out when it doesn't" do
    allow(Playback::FfmpegArgs::Input).to receive(:rtsp_tls_verify?).and_call_original
    Playback::FfmpegArgs::Input.instance_variable_set(:@rtsp_tls_verify, nil)
    allow(ToolRunner).to receive(:run).with(%w[ffmpeg -hide_banner -h demuxer=rtsp], timeout: 20)
      .and_return(ToolRunner::Result.new(status: 0, stdout: "RTSP demuxer AVOptions:\n  -rtsp_transport <flags>\n", stderr: ""))
    expect(described_class.build(camera, copy, directory: directory, profile: profile)).not_to include("-tls_verify")
  ensure
    Playback::FfmpegArgs::Input.instance_variable_set(:@rtsp_tls_verify, nil)
  end

  it "reads a camera over TCP with only RTSP's protocols, and maps tracks by position" do
    argv = described_class.build(camera, copy, directory: directory, profile: profile)
    ToolArgvGuard.check!(argv)

    expect(pairs(argv)).to include([ "-rtsp_transport", "tcp" ], [ "-tls_verify", "0" ], [ "-protocol_whitelist", "rtsp,rtsps,tcp,tls,udp,rtp,srtp" ],
      [ "-map", "0:v:0" ], [ "-map", "0:a:1" ], [ "-c:v", "copy" ], [ "-c:a", "copy" ], [ "-hls_segment_type", "fmp4" ])
    expect(argv.index("-rtsp_transport")).to be < argv.index("-i")
    expect(argv.last).to eq("/cache/live/key/index.m3u8")
  end

  it "never ends the playlist, numbers a fresh relay from the clock, and appends after a reconnect" do
    travel_to(Time.zone.at(1_791_000_000)) do
      fresh = described_class.build(camera, copy, directory: directory, profile: profile)
      flags = fresh[fresh.index("-hls_flags") + 1].split("+")
      expect(flags).to include("omit_endlist", "delete_segments", "temp_file")
      expect(flags).not_to include("append_list")
      expect(pairs(fresh)).to include([ "-start_number", "1791000000" ])

      again = described_class.build(camera, copy, directory: directory, profile: profile, append: true)
      expect(again[again.index("-hls_flags") + 1].split("+")).to include("append_list", "discont_start")
      expect(pairs(again)).to include([ "-start_number", "0" ])
    end
  end

  it "repackages copied AAC for MP4, and converts what it must with a keyframe every segment" do
    aac = copy.merge("audio" => { "index" => 0, "copy" => true, "codec" => "aac" })
    expect(pairs(described_class.build(camera, aac, directory: directory, profile: profile))).to include([ "-bsf:a", "aac_adtstoasc" ])

    convert = { "video" => { "index" => 2, "copy" => false, "codec" => "h264", "height" => 1080 }, "audio" => { "index" => 0, "copy" => false, "codec" => "aac" } }
    argv = described_class.build(camera, convert, directory: directory, profile: profile)
    expect(pairs(argv)).to include([ "-c:v", "libx264" ], [ "-force_key_frames", "expr:gte(t,n_forced*1)" ], [ "-c:a", "aac" ])
    expect(argv).not_to include("aac_adtstoasc")
    expect(argv).not_to include("-copyinkf:a")
  end

  it "copies audio from its first packet, keyframe or not (jellyfin-ffmpeg 7.1 marks no RTSP AAC packet one)" do
    aac = copy.merge("audio" => { "index" => 0, "copy" => true, "codec" => "aac" })
    expect(described_class.build(camera, aac, directory: directory, profile: profile)).to include("-copyinkf:a")
    expect(described_class.build(camera, copy.except("audio"), directory: directory, profile: profile)).not_to include("-copyinkf:a")
  end

  it "reads a YouTube stream's sound from its own playlist as the second input, over http(s) only" do
    youtube = LiveStream.new(name: "Lofi Girl", kind: "youtube", url: "https://www.youtube.com/watch?v=rFZHOHl-L8A").tap do |live|
      live.media_streams.build(index: 0, kind: "video", codec: "h264", height: 1080)
      live.media_streams.build(index: 1, kind: "audio", codec: "aac", channels: 2)
    end
    resolved = LiveStreams::Resolved.new(video: "https://example.googlevideo.com/v.m3u8", audio: "https://example.googlevideo.com/a.m3u8")
    decision = { "video" => { "index" => 0, "copy" => true, "codec" => "h264" }, "audio" => { "index" => 1, "copy" => true, "codec" => "aac" } }

    argv = described_class.build(youtube, decision, directory: directory, profile: profile, resolved: resolved)
    ToolArgvGuard.check!(argv)
    expect(argv.each_index.select { |index| argv[index] == "-i" }.map { |index| argv[index + 1] })
      .to eq([ resolved.video, resolved.audio ])
    expect(pairs(argv)).to include([ "-map", "0:v:0" ], [ "-map", "1:a:0" ], [ "-bsf:a", "aac_adtstoasc" ])
    expect(argv.count("http,https,tcp,tls,crypto")).to eq(2)
    expect(argv).not_to include("-user_agent")
  end

  it "reads MLB.tv's playlists with the User-Agent yt-dlp resolved them under, on each input, before its -i" do
    game = LiveStream.new(name: "Mariners", kind: "mlb", feed: "home", url: "https://www.mlb.com/tv/g745652/vafbc56d6").tap do |live|
      live.media_streams.build(index: 0, kind: "video", codec: "h264", height: 1080)
      live.media_streams.build(index: 1, kind: "audio", codec: "aac", channels: 2)
    end
    resolved = LiveStreams::Resolved.new(video: "https://tv-fst.mlb.test/v.m3u8", audio: "https://tv-fst.mlb.test/a.m3u8", user_agent: "Mozilla/5.0 (Chrome)")
    decision = { "video" => { "index" => 0, "copy" => true, "codec" => "h264" }, "audio" => { "index" => 1, "copy" => true, "codec" => "aac" } }

    argv = described_class.build(game, decision, directory: directory, profile: profile, resolved: resolved)
    ToolArgvGuard.check!(argv)
    inputs = argv.each_index.select { |index| argv[index] == "-i" }
    expect(inputs.map { |index| argv[index + 1] }).to eq([ resolved.video, resolved.audio ])
    agents = argv.each_index.select { |index| argv[index] == "-user_agent" }
    expect(agents.map { |index| argv[index + 1] }).to eq([ "Mozilla/5.0 (Chrome)" ] * 2)
    expect(agents.zip(inputs).all? { |agent, input| agent < input }).to be(true)
  end
end
