# typed: false
# frozen_string_literal: true

require "rails_helper"

# A live stream's decision (PROPOSAL §7.8): from its probed tracks, always
# relayed, copied wherever the browser decodes it.
RSpec.describe "Playback::Decision for a live stream" do
  let(:chrome) do
    Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4 webm], "video" => %w[h264 av1 vp9],
      "audio" => %w[aac mp3 opus], "max_audio_channels" => 2, "max_height" => 1080)
  end
  let(:safari) do
    Playback::Capabilities.from_json("hls" => "native", "containers" => %w[mp4], "video" => %w[h264 hevc],
      "audio" => %w[aac mp3 opus ac3 eac3], "max_audio_channels" => 6, "max_height" => 2160)
  end

  def stream(*tracks)
    live = LiveStream.new(name: "Front door", kind: "camera", url: "rtsps://192.168.1.1:7441/AbCdEfGhIjKlMnOp?enableSrtp")
    tracks.each_with_index { |attributes, index| live.media_streams.build({ index: index }.merge(attributes)) }
    live
  end

  # UniFi Protect's 4K share: AAC mono, Opus stereo, then the picture.
  let(:unifi) do
    stream({ kind: "audio", codec: "aac", channels: 1 }, { kind: "audio", codec: "opus", channels: 2 },
      { kind: "video", codec: "h264", bit_depth: 8, width: 3840, height: 2160 })
  end

  it "relays a 4K H.264 camera as it is, even to a 1080p screen" do
    decision = Playback::Decision.live(unifi, chrome, device_name: "Chrome")

    expect(decision.method).to eq(PlaybackSession::Method::Remux)
    expect(decision.video).to have_attributes(index: 2, copy: true, codec: "h264", height: 2160)
    expect(decision.audio).to have_attributes(index: 0, copy: true, codec: "aac")
    expect(decision.summary).to eq("Relayed live from rtsps://192.168.1.1:7441 — repackaged as it arrives, no quality loss")
  end

  it "converts only what the browser can't decode: HEVC for Chrome, a camera's G.711 for anyone" do
    hevc = stream({ kind: "video", codec: "hevc", bit_depth: 8, height: 1080 }, { kind: "audio", codec: "pcm_mulaw", channels: 1 })

    chrome_decision = Playback::Decision.live(hevc, chrome)
    expect(chrome_decision.method).to eq(PlaybackSession::Method::VideoTranscode)
    expect(chrome_decision.video).to have_attributes(copy: false, codec: "h264")
    expect(chrome_decision.audio).to have_attributes(copy: false, codec: "aac")

    safari_decision = Playback::Decision.live(hevc, safari)
    expect(safari_decision.method).to eq(PlaybackSession::Method::AudioTranscode)
    expect(safari_decision.video).to have_attributes(copy: true, codec: "hevc")
  end

  it "plays the sound that was asked for" do
    expect(Playback::Decision.live(unifi, chrome, audio_index: 1).audio).to have_attributes(index: 1, codec: "opus", copy: true)
  end

  it "can't play where there's no streaming at all" do
    nothing = Playback::Capabilities.from_json(chrome.to_json_hash.merge("hls" => "none"))
    expect(Playback::Decision.live(unifi, nothing).refusal).to include("can't play streamed video")
  end

  it "keys a relay by how it's relayed, however the decision's keys are ordered" do
    decision = Playback::Decision.live(unifi, chrome).to_h
    shuffled = JSON.parse(decision.to_json).transform_values { |value| value.is_a?(Hash) ? value.to_a.reverse.to_h : value }

    expect(Playback::LiveCache.key("s", decision)).to eq(Playback::LiveCache.key("s", shuffled))
    expect(Playback::LiveCache.key("s", decision)).not_to eq(Playback::LiveCache.key("s", Playback::Decision.live(unifi, chrome, audio_index: 1).to_h))
  end
end
