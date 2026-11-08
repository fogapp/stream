# typed: false
# frozen_string_literal: true

require "rails_helper"

# The optimized version's ffmpeg command (PROPOSAL §5.5): read the way its
# input says, carrying the track a session would play.
RSpec.describe Playback::OptimizeArgs do
  let(:profile) { Playback::Encoders::Profile.new(kind: Playback::Encoders::Kind::Software, tonemap_filter: nil) }
  let(:chrome) do
    Playback::Capabilities.from_json(
      "hls" => "mse", "containers" => %w[mp4 webm], "video" => %w[h264 av1 vp9],
      "audio" => %w[aac mp3 opus], "max_audio_channels" => 2, "hdr" => [], "max_height" => 2160
    )
  end

  def media_file(*audio)
    media = MediaFile.new(path: "/m/film.mkv", container: "matroska,webm", probe: {})
    media.media_streams.build(index: 0, kind: "video", codec: "hevc", bit_depth: 10, width: 1920, height: 1080)
    audio.each_with_index { |attributes, offset| media.media_streams.build({ index: offset + 1, kind: "audio", codec: "dts", channels: 6 }.merge(attributes)) }
    media
  end

  it "reads a remote transcoder's input with its reconnect options" do
    media = media_file({ default: true })
    plan = described_class.plan(media, max_height: 1080)
    input = Playback::FfmpegArgs::Input.remote("https://stream.lan/media/n/token/source")

    args = described_class.build(media, plan, output: "/c/out.mp4", progress: "pipe:1", profile: profile, input: input)

    whitelist = args.index("-protocol_whitelist")
    expect(args[whitelist, 4]).to eq([ "-protocol_whitelist", "http,https,tcp,tls", "-i", "https://stream.lan/media/n/token/source" ])
    expect(args[...whitelist]).to include("-reconnect", "-reconnect_on_http_error")
    expect(args.each_cons(2).to_a).to include([ "-reconnect_on_http_error", "5xx" ])
  end

  it "reads a local file as a file" do
    media = media_file({ default: true })
    args = described_class.build(media, described_class.plan(media, max_height: 1080), output: "/c/out.mp4", progress: "pipe:1", profile: profile)

    expect(args.each_cons(4).to_a).to include([ "-protocol_whitelist", "file", "-i", "file:/m/film.mkv" ])
    expect(args).not_to include("-reconnect")
  end

  # A commentary flagged default by mistake (R6) would make a version no
  # session plays: Decision picks the main track, and wants the version's
  # audio to be that one.
  describe "a commentary track flagged default" do
    before do
      @cache = Dir.mktmpdir("stream-cache")
      stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    end

    after { FileUtils.rm_rf(@cache) }

    it "carries the main track, so the version is one a session plays" do
      media = media_file({ default: true, comment: true }, { default: false })
      plan = described_class.plan(media, max_height: 1080)
      expect(plan.audio_index).to eq(2)

      version = media.build_optimized_version(id: SecureRandom.uuid, state: "ready", height: plan.height, audio_stream_index: plan.audio_index)
      version.path.dirname.mkpath
      version.path.write("mp4")

      decision = Playback::Decision.new(media, chrome, device_name: "This browser")
      expect(decision.method).to eq(PlaybackSession::Method::Optimized)
      expect(decision.audio.index).to eq(2)
    end
  end
end
