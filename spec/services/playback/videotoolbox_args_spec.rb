# typed: false
# frozen_string_literal: true

require "rails_helper"

# VideoToolbox converts on the media engine end to end: decoded there,
# scaled and tone-mapped there by scale_vt, encoded there. Decoding and
# tone mapping in software held 4K HDR10 under real time on an M1 (fog
# docs/compute-nodes-proposal.md › 12.1).
RSpec.describe "VideoToolbox arguments" do
  let(:videotoolbox) do
    Playback::Encoders::Profile.new(kind: Playback::Encoders::Kind::Videotoolbox,
      tonemap_filter: Playback::Encoders.tonemap_for(%w[zscale tonemap]))
  end
  let(:software) do
    Playback::Encoders::Profile.new(kind: Playback::Encoders::Kind::Software, tonemap_filter: Playback::Encoders.tonemap_for(%w[zscale tonemap]))
  end
  let(:bt709) { ":color_matrix=bt709:color_primaries=bt709:color_transfer=bt709" }

  def vf(argv) = argv[argv.index("-vf") + 1]

  it "decodes on the media engine and gives scale_vt a device" do
    expect(videotoolbox.device_args).to eq(%w[-hwaccel videotoolbox -init_hw_device videotoolbox=vt -filter_hw_device vt])
    expect(software.device_args).to eq([])
  end

  it "tone-maps in hardware, so HDR can always be made SDR there" do
    expect(videotoolbox).to have_attributes(hardware_tonemap?: true, tonemaps?: true, tonemap_name: "scale_vt")
    without = Playback::Encoders::Profile.new(kind: Playback::Encoders::Kind::Software, tonemap_filter: nil)
    expect(without).to have_attributes(hardware_tonemap?: false, tonemaps?: false, tonemap_name: "none")
    expect(software.tonemap_name).to eq("zscale")
  end

  it "scales on the media engine, tone-mapping as it goes when asked" do
    plain = Playback::FfmpegArgs.encoder_args([], 1080, "expr:gte(t,n_forced*6)", Playback::Encoders::Kind::Videotoolbox)
    expect(vf(plain)).to eq("hwupload,scale_vt=w=-2:h=1080")
    expect(plain).to include("h264_videotoolbox")

    hdr = Playback::FfmpegArgs.encoder_args([ "bwdif=mode=send_frame" ], 720, "source", Playback::Encoders::Kind::Videotoolbox, tonemap: true)
    expect(vf(hdr)).to eq("bwdif=mode=send_frame,hwupload,scale_vt=w=-2:h=720#{bt709}")
  end

  def plan_of(video) = Playback::FfmpegArgs::VideoPlan.from(video)

  it "leaves the software tone map out of a session's chain unless a subtitle is drawn in" do
    video = { "index" => 0, "copy" => false, "height" => 1080, "tonemap" => true }
    args = Playback::FfmpegArgs.video_args(plan_of(video), 0.0, videotoolbox, 6.0)
    expect(vf(args)).to eq("hwupload,scale_vt=w=-2:h=1080#{bt709}")

    # R6: a picture subtitle lands on SDR, so the picture is tone-mapped
    # in software before the overlay, and scale_vt only scales.
    burned = Playback::FfmpegArgs.video_args(plan_of(video.merge("burn_subtitle" => 3)), 0.0, videotoolbox, 6.0)
    expect(vf(burned)).to start_with("zscale=t=linear")
    expect(vf(burned)).to end_with("hwupload,scale_vt=w=-2:h=1080")

    expect(vf(Playback::FfmpegArgs.video_args(plan_of(video), 0.0, software, 6.0))).to start_with("zscale=t=linear")
  end

  it "makes an optimized version on the media engine too" do
    plan = Playback::OptimizeArgs::Plan.new(video_index: 0, audio_index: nil, height: 1080, tonemap: true)
    args = Playback::OptimizeArgs.video_args(plan, videotoolbox)
    expect(vf(args)).to eq("hwupload,scale_vt=w=-2:h=1080#{bt709}")
  end

  it "really turns HDR10 into BT.709 SDR on a Mac", if: RUBY_PLATFORM.include?("darwin") do
    require_ffprobe!
    source = Rails.root.join("spec/fixtures/media/hevc_main10_hdr10.mkv").to_s
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out.mp4")
      argv = %w[ffmpeg -hide_banner -v error -nostdin -y] + videotoolbox.device_args +
        [ "-protocol_whitelist", "file", "-i", "file:#{source}", "-map", "0:v:0" ] +
        Playback::FfmpegArgs.video_args(plan_of("index" => 0, "copy" => false, "height" => 360, "tonemap" => true), 0.0, videotoolbox, 6.0) +
        [ "-an", out ]
      ToolArgvGuard.check!(argv)
      result = ToolRunner.run(argv, timeout: 120)
      expect(result.stderr).to eq("")
      video = JSON.parse(ToolRunner.run(%W[ffprobe -v error -show_streams -of json #{out}]).stdout)["streams"].first
      expect(video).to include("codec_name" => "h264", "pix_fmt" => "yuv420p", "height" => 360, "color_transfer" => "bt709")
    end
  end
end
