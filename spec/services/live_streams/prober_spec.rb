# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveStreams::Prober do
  let(:household) { Household.create!(name: "Family") }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:token) { "AbCdEfGhIjKlMnOp" }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera", trust_certificate: true,
      url: "rtsps://192.168.1.1:7441/#{token}?enableSrtp")
  end
  # What UniFi Protect's 4K share answers (2026-10-09).
  let(:unifi) do
    {
      "streams" => [
        { "index" => 0, "codec_type" => "audio", "codec_name" => "aac", "profile" => "LC", "sample_rate" => "48000", "channels" => 1 },
        { "index" => 1, "codec_type" => "audio", "codec_name" => "opus", "sample_rate" => "48000", "channels" => 2 },
        { "index" => 2, "codec_type" => "video", "codec_name" => "h264", "profile" => "Main", "width" => 3840, "height" => 2160,
          "pix_fmt" => "yuv420p", "r_frame_rate" => "24/1", "avg_frame_rate" => "24/1" }
      ],
      "format" => { "format_name" => "rtsp", "filename" => "rtsps://192.168.1.1:7441/#{token}?enableSrtp" }
    }.to_json
  end

  # ffmpeg 9's RTSP demuxer takes -tls_verify; 7.1's doesn't (a case below).
  before { allow(Playback::FfmpegArgs::Input).to receive(:rtsp_tls_verify?).and_return(true) }

  def answer(stdout: "", stderr: "", status: 0)
    seen = []
    allow(ToolRunner).to receive(:version).and_return("ffprobe version 7.1.4-Jellyfin")
    allow(ToolRunner).to receive(:run) do |argv, **|
      ToolArgvGuard.check!(argv)
      seen << argv
      ToolRunner::Result.new(status: status, stdout: stdout, stderr: stderr)
    end
    seen
  end

  it "reads a camera over TCP, trusting its own certificate, and keeps its tracks as rows" do
    seen = answer(stdout: unifi)

    described_class.call(stream)

    argv = seen.last
    expect(argv.each_cons(2).to_a).to include([ "-rtsp_transport", "tcp" ], [ "-tls_verify", "0" ],
      [ "-protocol_whitelist", "rtsp,rtsps,tcp,tls,udp,rtp,srtp" ])
    expect(argv.join(" ")).not_to match(/whitelist \S*file/)
    expect(stream.reload.media_streams.map { |row| [ row.kind, row.codec, row.height ] })
      .to eq([ [ "audio", "aac", nil ], [ "audio", "opus", nil ], [ "video", "h264", 2160 ] ])
    expect(stream).to have_attributes(status: "online", container: "rtsp", consecutive_failures: 0)
    expect(stream.analysis_runs.sole).to have_attributes(step: "probe", status: "succeeded")
  end

  it "verifies a certificate unless the stream trusts its own" do
    stream.update!(trust_certificate: false)
    seen = answer(stdout: unifi)
    described_class.probe(stream)
    expect(seen.last).not_to include("-tls_verify")
  end

  it "leaves -tls_verify out where the build's RTSP demuxer doesn't take it, and says so plainly if one ever refuses an option" do
    allow(Playback::FfmpegArgs::Input).to receive(:rtsp_tls_verify?).and_return(false)
    seen = answer(stdout: unifi)
    described_class.probe(stream)
    expect(seen.last).not_to include("-tls_verify")

    answer(status: 1, stderr: "Option tls_verify not found.\nError opening input files: Option not found\n")
    expect { described_class.probe(stream) }.to raise_error(described_class::Failure, /doesn't take the option tls_verify/)
  end

  it "records an unreachable source as offline, in words without the address" do
    answer(status: 1, stderr: "[tls @ 0x1] Peer certificate failed verification\nrtsps://192.168.1.1:7441/#{token}?enableSrtp: Input/output error\n")
    stream.update!(trust_certificate: false)

    expect { described_class.call(stream) }.to raise_error(described_class::Failure, /certificate isn't trusted/)

    stream.reload
    expect(stream).to have_attributes(status: "offline", consecutive_failures: 1)
    expect(stream.last_error).to include("rtsps://192.168.1.1:7441").and(include("Trust its certificate"))
    run = stream.analysis_runs.sole
    expect(run).to have_attributes(status: "failed", consecutive_failures: 1)
    expect([ stream.last_error, run.error ].join).not_to include(token)
  end

  it "redacts a message it doesn't recognise" do
    answer(status: 1, stderr: "rtsps://192.168.1.1:7441/#{token}?enableSrtp: Something unheard of\n")
    expect { described_class.probe(stream) }.to raise_error(described_class::Failure) { |error|
      expect(error.message).to eq("rtsps://192.168.1.1:7441: Something unheard of")
    }
  end

  it "refuses a stream with no picture" do
    answer(stdout: { "streams" => [ { "index" => 0, "codec_type" => "audio", "codec_name" => "aac", "channels" => 2 } ] }.to_json)
    expect { described_class.probe(stream) }.to raise_error(described_class::Failure, "There's no video in this stream")
  end

  it "reads a web stream over http(s) only" do
    web = LiveStream.new(household: household, library: library, name: "News", kind: "web", url: "https://example.com/live/index.m3u8")
    seen = answer(stdout: unifi)
    described_class.probe(web)
    expect(seen.last.each_cons(2).to_a).to include([ "-protocol_whitelist", "http,https,tcp,tls,crypto" ])
    expect(seen.last).not_to include("-rtsp_transport")
  end

  it "reads a YouTube stream's picture and sound from their own playlists, numbering the sound after the picture" do
    youtube = LiveStream.new(household: household, library: library, name: "Lofi Girl", kind: "youtube", url: "https://youtu.be/rFZHOHl-L8A")
    allow(LiveStreams::YoutubeSource).to receive(:resolve).with(youtube)
      .and_return(LiveStreams::Resolved.new(video: "https://example.googlevideo.com/v.m3u8", audio: "https://example.googlevideo.com/a.m3u8"))
    picture = { "streams" => [ { "index" => 0, "codec_type" => "video", "codec_name" => "h264", "width" => 1920, "height" => 1080,
                                 "pix_fmt" => "yuv420p", "r_frame_rate" => "30/1" } ], "format" => { "format_name" => "hls" } }
    sound = { "streams" => [ { "index" => 0, "codec_type" => "audio", "codec_name" => "aac", "sample_rate" => "44100", "channels" => 2 } ],
              "format" => { "format_name" => "hls" } }
    seen = []
    allow(ToolRunner).to receive(:run) do |argv, **|
      ToolArgvGuard.check!(argv)
      seen << argv
      ToolRunner::Result.new(status: 0, stdout: (argv.last.end_with?("a.m3u8") ? sound : picture).to_json, stderr: "")
    end

    result = described_class.probe(youtube)
    expect(seen.map(&:last)).to eq([ "https://example.googlevideo.com/v.m3u8", "https://example.googlevideo.com/a.m3u8" ])
    expect(result.container).to eq("hls")
    expect(result.streams.map { |row| [ row[:index], row[:kind], row[:codec] ] }).to eq([ [ 0, "video", "h264" ], [ 1, "audio", "aac" ] ])
  end

  it "fails a YouTube stream that isn't live without asking ffprobe" do
    youtube = LiveStream.new(household: household, library: library, name: "Lofi Girl", kind: "youtube", url: "https://youtu.be/rFZHOHl-L8A")
    allow(LiveStreams::YoutubeSource).to receive(:resolve).and_raise(described_class::Failure, "Lofi Girl isn't live on YouTube right now")
    seen = answer(stdout: unifi)
    expect { described_class.probe(youtube) }.to raise_error(described_class::Failure, "Lofi Girl isn't live on YouTube right now")
    expect(seen).to be_empty
  end
end
