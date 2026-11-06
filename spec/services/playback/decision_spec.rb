# typed: false
# frozen_string_literal: true

require "rails_helper"

# The decision table (PROPOSAL §6.2, §8.4): file streams × capability
# profile → method and reasons. Profiles are what the browsers report on a
# 2025 Mac: Chrome decodes no AC-3 and has no HEVC; Safari has HEVC, HDR on
# an XDR screen and E-AC-3, but no MKV and no VP9.
RSpec.describe Playback::Decision do
  CHROME = Playback::Capabilities.from_json(
    "hls" => "mse", "containers" => %w[mp4 webm], "video" => %w[h264 av1 av1_10 vp9 vp9_10 vp8],
    "audio" => %w[aac mp3 opus flac vorbis], "max_audio_channels" => 2, "hdr" => [], "max_height" => 2160
  )
  SAFARI = Playback::Capabilities.from_json(
    "hls" => "native", "containers" => %w[mp4], "video" => %w[h264 hevc hevc_10 av1 av1_10],
    "audio" => %w[aac mp3 alac flac opus ac3 eac3], "max_audio_channels" => 6,
    "hdr" => %w[hdr10 hlg dolby_vision], "max_height" => 2160
  )
  SAFARI_SDR = Playback::Capabilities.from_json(SAFARI.to_json_hash.merge("hdr" => []))

  def file(path, container, *streams, tags: {})
    media = MediaFile.new(path: path, container: container,
      probe: { "streams" => tags.map { |index, tag| { "index" => index, "codec_tag_string" => tag } } })
    streams.each_with_index do |attributes, index|
      media.media_streams.build({ index: index, default: index == 1 }.merge(attributes))
    end
    media
  end

  def video(codec, bit_depth: 8, height: 1080, hdr: nil, dv: nil)
    { kind: "video", codec: codec, bit_depth: bit_depth, width: height * 16 / 9, height: height, hdr_format: hdr,
      dolby_vision_profile: dv }
  end

  def audio(codec, channels: 2, default: false) = { kind: "audio", codec: codec, channels: channels, default: default }

  MP4 = "mov,mp4,m4a,3gp,3g2,mj2"
  MKV = "matroska,webm"

  def decide(media, caps, **options) = described_class.new(media, caps, device_name: "This browser", **options)

  it "direct-plays an MP4 with web codecs everywhere" do
    media = file("/m/a.mp4", MP4, video("h264"), audio("aac"))
    [ CHROME, SAFARI ].each do |caps|
      decision = decide(media, caps)
      expect(decision.method).to eq(PlaybackSession::Method::Direct)
      expect(decision.summary).to eq("Plays as-is")
      expect(decision.direct_mime_type).to eq("video/mp4")
    end
  end

  it "remuxes an MKV, with the reason in plain words" do
    decision = decide(file("/m/a.mkv", MKV, video("h264"), audio("aac")), SAFARI)
    expect(decision.method).to eq(PlaybackSession::Method::Remux)
    expect(decision.summary).to eq("This browser can't open MKV files — repackaged, no quality loss")
    expect(decision.video).to have_attributes(copy: true)
  end

  it "converts DTS to stereo AAC for Chrome and to 5.1 E-AC-3 for Safari" do
    media = file("/m/a.mkv", MKV, video("h264"), audio("dts", channels: 6))

    chrome = decide(media, CHROME)
    expect(chrome.method).to eq(PlaybackSession::Method::AudioTranscode)
    expect(chrome.audio).to have_attributes(copy: false, codec: "aac", channels: 2)
    expect(chrome.summary).to eq("DTS 5.1 audio isn't supported here — converted to AAC stereo")

    safari = decide(media, SAFARI)
    expect(safari.audio).to have_attributes(codec: "eac3", channels: 6)
  end

  it "converts an AVI's MPEG-4 Part 2 and MP3 to H.264 and AAC, since fMP4 can't carry MP3 to a browser" do
    media = file("/m/a.avi", "avi", video("mpeg4", height: 352), audio("mp3"))
    [ CHROME, SAFARI ].each do |caps|
      decision = decide(media, caps)
      expect(decision.method).to eq(PlaybackSession::Method::VideoTranscode)
      expect(decision.video).to have_attributes(copy: false, codec: "h264", height: 352)
      expect(decision.audio).to have_attributes(copy: false, codec: "aac", channels: 2)
      expect(decision.reasons.last).to eq("MP3 stereo audio doesn't stream as-is — converted to AAC stereo")
    end
  end

  it "converts MP3 when an MKV is repackaged, but plays it as-is in an MP4" do
    remux = decide(file("/m/a.mkv", MKV, video("h264"), audio("mp3")), CHROME)
    expect(remux.method).to eq(PlaybackSession::Method::AudioTranscode)
    expect(remux.audio).to have_attributes(copy: false, codec: "aac")

    direct = decide(file("/m/a.mp4", MP4, video("h264"), audio("mp3")), CHROME)
    expect(direct.method).to eq(PlaybackSession::Method::Direct)
    expect(direct.audio).to have_attributes(copy: true, codec: "mp3")
  end

  it "keeps 10-bit HEVC HDR10 for Safari on an HDR screen and tone-maps it everywhere else" do
    media = file("/m/a.mkv", MKV, video("hevc", bit_depth: 10, height: 2160, hdr: "hdr10"), audio("aac"))

    expect(decide(media, SAFARI).method).to eq(PlaybackSession::Method::Remux)

    sdr = decide(media, SAFARI_SDR)
    expect(sdr.method).to eq(PlaybackSession::Method::VideoTranscode)
    expect(sdr.video).to have_attributes(codec: "h264", height: 1080, tonemap: true)
    expect(sdr.summary).to eq("HDR on a screen that can't show it — tone-mapped to SDR H.264 1080p")

    chrome = decide(media, CHROME)
    expect(chrome.summary).to eq("10-bit HEVC video isn't supported here — converted to H.264 1080p with tone mapping")
  end

  it "lets a hardware encoder keep 4K" do
    media = file("/m/a.mkv", MKV, video("hevc", bit_depth: 10, height: 2160, hdr: "hdr10"), audio("aac"))
    expect(decide(media, CHROME, max_height: 2160).video.height).to eq(2160)
  end

  it "converts what no browser decodes: MPEG-2, 10-bit H.264" do
    [ file("/m/old.ts", "mpegts", video("mpeg2video", height: 576), audio("mp2")),
      file("/m/anime.mkv", MKV, video("h264", bit_depth: 10), audio("aac")) ].each do |media|
      [ CHROME, SAFARI ].each do |caps|
        expect(decide(media, caps).method).to eq(PlaybackSession::Method::VideoTranscode)
      end
    end
    expect(decide(file("/m/old.ts", "mpegts", video("mpeg2video", height: 576), audio("mp2")), CHROME).video.height).to eq(576)
  end

  it "plays WebM VP9 directly in Chrome and converts it for Safari" do
    media = file("/m/a.webm", MKV, video("vp9"), audio("opus"))
    expect(decide(media, CHROME)).to have_attributes(method: PlaybackSession::Method::Direct, direct_mime_type: "video/webm")
    expect(decide(media, SAFARI).method).to eq(PlaybackSession::Method::VideoTranscode)
  end

  it "retags hev1 HEVC as hvc1 for Safari rather than converting it" do
    decision = decide(file("/m/a.mp4", MP4, video("hevc"), audio("aac"), tags: { 0 => "hev1" }), SAFARI)
    expect(decision.method).to eq(PlaybackSession::Method::Remux)
    expect(decision.video.retag_hvc1).to be(true)
    expect(decision.summary).to include("hev1")
  end

  it "remuxes to play an audio track other than the first" do
    media = file("/m/a.mp4", MP4, video("h264"), audio("aac"), audio("aac"))
    decision = decide(media, CHROME, audio_index: 2)
    expect(decision.method).to eq(PlaybackSession::Method::Remux)
    expect(decision.audio.index).to eq(2)
    expect(decision.summary).to include("only plays the first audio track")
  end

  # The browser scales far more cheaply
  # than a conversion; a 1080p file on a 768-line laptop used to be converted.
  it "plays video taller than the screen as it is, and sizes only a conversion to the screen" do
    small = Playback::Capabilities.from_json(CHROME.to_json_hash.merge("max_height" => 720))
    decision = decide(file("/m/a.mp4", MP4, video("h264", height: 1080), audio("aac")), small)
    expect(decision.method).to eq(PlaybackSession::Method::Direct)
    converted = decide(file("/m/a.mkv", MKV, video("mpeg2video", height: 1080), audio("aac")), small)
    expect(converted.video).to have_attributes(copy: false, height: 720)
  end

  describe "what can't be copied though the codec is taken (R6)" do
    def blocked(stream, caps = CHROME)
      decide(file("/m/a.mkv", MKV, video("h264").merge(stream), audio("aac")), caps)
    end

    it "converts 4:2:2 and 4:4:4 H.264, which no browser decodes" do
      decision = blocked(chroma: "422")
      expect(decision.method).to eq(PlaybackSession::Method::VideoTranscode)
      expect(decision.summary).to eq("4:2:2 H.264 video isn't decoded by browsers — converted to H.264 1080p")
      expect(decision.reason_codes).to eq(%w[chroma])
      expect(blocked(chroma: "420").video.copy).to be(true)
    end

    it "deinterlaces interlaced video as it converts it" do
      decision = blocked(field_order: "tt")
      expect(decision.video).to have_attributes(copy: false, deinterlace: true)
      expect(decision.summary).to eq("Interlaced H.264 video — deinterlaced and converted to H.264 1080p")
      expect(blocked(field_order: "progressive").video.copy).to be(true)
    end

    it "converts a level the client said it can't decode, and a size it can't decode smoothly" do
      levelled = Playback::Capabilities.from_json(CHROME.to_json_hash.merge("levels" => { "h264" => 42 }, "smooth" => { "h264" => 1080 }))
      expect(blocked({ level: 51 }, levelled).summary).to start_with("H.264 at level 5.1 is more than this device decodes")
      expect(blocked({ level: 41 }, levelled).video.copy).to be(true)
      expect(blocked({ level: 41, height: 2160 }, levelled).summary).to start_with("2160p H.264 doesn't play smoothly here")
    end

    it "converts what the streaming path won't take though a file opened directly would" do
      split = Playback::Capabilities.from_json(SAFARI.to_json_hash.merge("stream_video" => %w[h264]))
      direct = decide(file("/m/a.mp4", MP4, video("hevc"), audio("aac"), tags: { 0 => "hvc1" }), split)
      expect(direct.method).to eq(PlaybackSession::Method::Direct)
      streamed = decide(file("/m/a.mkv", MKV, video("hevc"), audio("aac")), split)
      expect(streamed.method).to eq(PlaybackSession::Method::VideoTranscode)
      expect(streamed.summary).to eq("HEVC video plays as a file here, not streamed — converted to H.264 1080p")
    end

    it "turns sideways video upright when it's streamed, and leaves a file it plays directly to the browser" do
      expect(decide(file("/m/a.mp4", MP4, video("h264").merge(rotation: 90), audio("aac")), CHROME).method)
        .to eq(PlaybackSession::Method::Direct)
      streamed = decide(file("/m/a.mkv", MKV, video("h264").merge(rotation: -90), audio("aac")), CHROME)
      expect(streamed.method).to eq(PlaybackSession::Method::VideoTranscode)
      expect(streamed.reason_codes).to include("rotation")
    end

    it "takes away what a browser is known to claim and fail on" do
      safari = described_class.new(file("/m/a.mp4", MP4, video("h264", bit_depth: 10), audio("aac")),
        Playback::Capabilities.from_json(SAFARI.to_json_hash.merge("video" => SAFARI.video + %w[h264_10])), device_name: "Safari on macOS")
      expect(safari.video.copy).to be(false)
    end
  end

  describe "Dolby Vision (R6)" do
    def dv(profile, compatibility: nil)
      media = file("/m/a.mkv", MKV, video("hevc", bit_depth: 10, hdr: "dolby_vision", dv: profile), audio("aac"))
      if compatibility
        media.probe = { "streams" => [ { "index" => 0, "side_data_list" => [ { "side_data_type" => "DOVI configuration record",
          "dv_bl_signal_compatibility_id" => compatibility } ] } ] }
      end
      media
    end

    let(:hdr10) { Playback::Capabilities.from_json(SAFARI.to_json_hash.merge("hdr" => %w[hdr10])) }

    it "copies profile 5 tagged dvh1 to a client with Dolby Vision, and converts it for one without" do
      expect(decide(dv(5), SAFARI).video).to have_attributes(copy: true, dv_tag: "dvh1", dv_strip: false)
      expect(decide(dv(5), hdr10).video).to have_attributes(copy: false, tonemap: true)
    end

    it "plays profiles 7 and 8 as HDR10 with the RPU stripped where there's no Dolby Vision, and 8.4 needs HLG" do
      expect(decide(dv(7, compatibility: 6), hdr10).video).to have_attributes(copy: true, dv_strip: true)
      expect(decide(dv(8, compatibility: 1), hdr10).video).to have_attributes(copy: true, dv_strip: true)
      expect(decide(dv(8, compatibility: 1), SAFARI).video).to have_attributes(copy: true, dv_strip: false)
      expect(decide(dv(7, compatibility: 6), SAFARI).video).to have_attributes(copy: true, dv_strip: true)
      expect(decide(dv(8, compatibility: 4), hdr10).video.copy).to be(false)
    end
  end

  describe "sound (R6)" do
    it "doesn't pick a commentary flagged default over the film's own sound" do
      media = file("/m/a.mkv", MKV, video("h264"), audio("aac").merge(comment: true, default: true), audio("aac"))
      expect(decide(media, CHROME).audio.index).to eq(2)
    end

    it "converts sound above 48 kHz when it's streamed" do
      media = file("/m/a.mkv", MKV, video("h264"), audio("flac").merge(sample_rate: 96_000))
      decision = decide(media, CHROME)
      expect(decision.audio).to have_attributes(copy: false, codec: "aac")
      expect(decision.summary).to start_with("FLAC stereo audio at 96 kHz doesn't stream as-is")
    end
  end

  it "treats Dolby Vision profile 8 as HDR10 but converts profile 5" do
    caps = Playback::Capabilities.from_json(SAFARI.to_json_hash.merge("hdr" => %w[hdr10]))
    profile8 = file("/m/a.mkv", MKV, video("hevc", bit_depth: 10, hdr: "dolby_vision", dv: 8), audio("aac"))
    profile5 = file("/m/b.mkv", MKV, video("hevc", bit_depth: 10, hdr: "dolby_vision", dv: 5), audio("aac"))
    expect(decide(profile8, caps).video.copy).to be(true)
    expect(decide(profile5, caps).video.tonemap).to be(true)
  end

  it "refuses plainly when the browser can stream nothing" do
    caps = Playback::Capabilities.from_json(CHROME.to_json_hash.merge("hls" => "none"))
    decision = decide(file("/m/a.mkv", MKV, video("h264"), audio("aac")), caps)
    expect(decision.playable?).to be(false)
    expect(decision.summary).to include("can't play streamed video")
  end

  it "reads a missing or garbled profile as the conservative baseline" do
    caps = Playback::Capabilities.from_json("video" => "not a list", "bogus" => 1)
    expect(caps).to have_attributes(video: [], audio: %w[aac mp3], containers: %w[mp4], max_audio_channels: 2)
    expect(Playback::Capabilities.from_json(nil).video).to eq(%w[h264])
  end

  # CLAUDE.md invariant 3, across the whole table rather than a row at a
  # time: every way off direct play says why, and the video is converted only
  # when it can't be copied.
  it "gives a reason for everything but direct play, and converts video only when it can't be copied" do
    videos = [ video("h264"), video("h264", height: 2160), video("hevc"), video("hevc", bit_depth: 10, hdr: "hdr10"),
               video("hevc", bit_depth: 10, hdr: "dolby_vision", dv: 5), video("av1", bit_depth: 10), video("vp9"),
               video("mpeg2video"), video("vc1"), video("mpeg4") ]
    audios = [ audio("aac"), audio("ac3", channels: 6), audio("eac3", channels: 6), audio("dts", channels: 6), audio("truehd", channels: 8),
               audio("flac"), audio("opus"), audio("mp2") ]
    containers = { "mp4" => MP4, "mkv" => MKV, "ts" => "mpegts" }
    small = Playback::Capabilities.from_json(CHROME.to_json_hash.merge("max_height" => 1080))
    checked = 0

    containers.each do |extension, container|
      videos.product(audios, [ CHROME, SAFARI, SAFARI_SDR, small ]).each do |picture, sound, caps|
        decision = decide(file("/m/a.#{extension}", container, picture, sound.merge(default: true)), caps)
        next unless decision.playable?

        label = "#{extension} #{picture[:codec]} #{picture[:bit_depth]}-bit #{picture[:height]}p #{sound[:codec]}"
        method = decision.method
        expect(decision.reasons).to be_present, "#{label}: #{method.serialize} without a reason" unless method == PlaybackSession::Method::Direct
        converting = method == PlaybackSession::Method::VideoTranscode
        expect(decision.video.copy).to be(!converting), "#{label}: #{method.serialize} but video copy=#{decision.video.copy}"
        checked += 1
      end
    end

    expect(checked).to be > 500
  end

  describe "with an optimized version (PROPOSAL §5.5)" do
    def hevc_file
      file("/m/b.mkv", MKV, video("hevc", bit_depth: 10), audio("dts", channels: 6, default: true), audio("aac"))
    end

    # Ready means the row says so and the file is really there.
    before do
      @cache = Dir.mktmpdir("stream-cache")
      stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    end

    after { FileUtils.rm_rf(@cache) }

    def with_version(media, state: "ready", height: 1080, audio_stream_index: 1)
      version = media.build_optimized_version(id: SecureRandom.uuid, state: state, height: height, audio_stream_index: audio_stream_index)
      version.path.dirname.mkpath
      version.path.write("mp4") if state == "ready"
      media
    end

    it "plays it as-is where the original would need its video converted" do
      media = with_version(hevc_file)
      decision = decide(media, CHROME)
      expect(decision.method).to eq(PlaybackSession::Method::Optimized)
      expect(decision.summary).to eq("10-bit HEVC video isn't supported here — plays the optimized H.264 1080p version made ahead of time")
      expect(decision.reasons.size).to eq(1)
      expect(decision.direct_mime_type).to eq("video/mp4")
      expect(decision.to_h["optimized_version_id"]).to eq(media.optimized_version.id)
      expect(decision.audio).to have_attributes(copy: true, codec: "aac")
    end

    it "prefers the original wherever it plays without converting video" do
      decision = decide(with_version(hevc_file), SAFARI)
      expect(decision.method).to eq(PlaybackSession::Method::AudioTranscode)
      expect(decision.to_h).not_to have_key("optimized_version_id")
    end

    it "converts live when another audio track is chosen, one isn't ready, or it's too tall" do
      expect(decide(with_version(hevc_file), CHROME, audio_index: 2).method).to eq(PlaybackSession::Method::VideoTranscode)
      expect(decide(with_version(hevc_file, state: "queued"), CHROME).method).to eq(PlaybackSession::Method::VideoTranscode)
      small = Playback::Capabilities.from_json(CHROME.to_json_hash.merge("max_height" => 720))
      expect(decide(with_version(hevc_file), small).method).to eq(PlaybackSession::Method::VideoTranscode)
    end
  end
end
