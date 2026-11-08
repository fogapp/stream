# typed: false
# frozen_string_literal: true

require "rails_helper"

# The encoder's end of every conversion, pinned argument for argument: a
# session's run and an optimized version share one table (EncoderArgs), and
# a change to either is a change to what ffmpeg is told.
RSpec.describe Playback::EncoderArgs do
  live = described_class::Quality::Live
  optimize = described_class::Quality::Optimize
  kind = Playback::Encoders::Kind

  {
    [ kind::Vaapi, live ] => [
      %w[format=nv12 hwupload scale_vaapi=w=-2:h=1080],
      %w[-c:v h264_vaapi -qp 22 -force_key_frames KF]
    ],
    [ kind::Vaapi, optimize ] => [
      %w[format=nv12 hwupload scale_vaapi=w=-2:h=1080],
      %w[-c:v h264_vaapi -qp 20 -profile:v high -force_key_frames KF]
    ],
    [ kind::Software, live ] => [
      %w[scale=-2:1080:flags=bicubic format=yuv420p],
      %w[-c:v libx264 -preset veryfast -crf 21 -maxrate 10000k -bufsize 20000k -profile:v high -sc_threshold 0 -force_key_frames KF]
    ],
    [ kind::Software, optimize ] => [
      %w[scale=-2:1080:flags=lanczos format=yuv420p],
      %w[-c:v libx264 -preset slow -crf 20 -profile:v high -maxrate 10000k -bufsize 20000k -force_key_frames KF]
    ],
    [ kind::Videotoolbox, live ] => [
      %w[hwupload scale_vt=w=-2:h=1080],
      %w[-c:v h264_videotoolbox -realtime 1 -profile:v high -b:v 5000k -maxrate 10000k -bufsize 20000k -force_key_frames KF]
    ],
    [ kind::Videotoolbox, optimize ] => [
      %w[hwupload scale_vt=w=-2:h=1080],
      %w[-c:v h264_videotoolbox -profile:v high -b:v 6000k -maxrate 10000k -bufsize 20000k -force_key_frames KF]
    ]
  }.each do |(encoder, quality), (filters, codec)|
    it "gives #{encoder.serialize} its #{quality.serialize} arguments" do
      encoding = described_class.for(encoder, height: 1080, keyframes: "KF", quality: quality)
      expect(encoding.filters).to eq(filters)
      expect(encoding.codec).to eq(codec)
    end
  end

  it "tone-maps in scale_vt only when asked" do
    encoding = described_class.for(kind::Videotoolbox, height: 720, keyframes: "KF", quality: optimize, tonemap: true)
    expect(encoding.filters.last).to eq("scale_vt=w=-2:h=720:color_matrix=bt709:color_primaries=bt709:color_transfer=bt709")
    expect(described_class.for(kind::Software, height: 720, keyframes: "KF", quality: live, tonemap: true).filters)
      .to eq(%w[scale=-2:720:flags=bicubic format=yuv420p])
  end

  it "makes a session's run's whole -vf and codec from it" do
    profile = Playback::Encoders::Profile.new(kind: kind::Software, tonemap_filter: nil)
    video = Playback::FfmpegArgs::VideoPlan.from("index" => 0, "copy" => false, "height" => 720, "deinterlace" => true)
    expect(Playback::FfmpegArgs.video_args(video, 0.0, profile, 2.0)).to eq(
      [ "-vf", "bwdif=mode=send_frame,scale=-2:720:flags=bicubic,format=yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
        "-maxrate", "5000k", "-bufsize", "10000k", "-profile:v", "high", "-sc_threshold", "0",
        "-force_key_frames", Playback::FfmpegArgs.grid_keyframes(2.0) ]
    )
  end

  it "makes an optimized version's whole -vf and codec from it" do
    profile = Playback::Encoders::Profile.new(kind: kind::Vaapi, tonemap_filter: "tonemapx=x")
    plan = Playback::OptimizeArgs::Plan.new(video_index: 0, audio_index: nil, height: 2160, tonemap: true)
    expect(Playback::OptimizeArgs.video_args(plan, profile)).to eq(
      [ "-vf", "tonemapx=x,format=nv12,hwupload,scale_vaapi=w=-2:h=2160", "-c:v", "h264_vaapi", "-qp", "20", "-profile:v", "high",
        "-force_key_frames", "expr:gte(t,n_forced*2)" ]
    )
  end

  # R6: the subtitle lands on the picture once it's SDR, so the whole tone
  # map — the zscale chain's closing format=yuv420p included — comes before
  # the overlay, and only the encoder's own filters after it.
  it "draws a burned-in subtitle over the finished tone map" do
    profile = Playback::Encoders::Profile.new(kind: kind::Software, tonemap_filter: Playback::Encoders.tonemap_for(%w[zscale tonemap]))
    file = MediaFile.new(path: "/m/film.mkv", container: "matroska,webm", probe: {})
    video = { "index" => 0, "copy" => false, "height" => 1080, "tonemap" => true, "deinterlace" => true, "burn_subtitle" => 3 }
    session = PlaybackSession.new(media_file: file, decision: { "video" => video })
    argv = Playback::FfmpegArgs.build(session, Playback::SegmentPlan.grid(60_000), start_gop: 0, directory: Pathname("/c/run"), profile: profile)

    expect(argv).not_to include("-vf")
    expect(argv[argv.index("-filter_complex") + 1]).to eq(
      "[0:0]bwdif=mode=send_frame,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0," \
      "zscale=t=bt709:m=bt709:r=tv,format=yuv420p[picture];[0:3][picture]scale2ref=w=main_w:h=main_h[sub][base];" \
      "[base][sub]overlay=eof_action=pass:repeatlast=0,scale=-2:1080:flags=bicubic,format=yuv420p[burned]"
    )
    expect(argv.each_cons(2).to_a).to include([ "-map", "[burned]" ], %w[-c:v libx264])
  end
end
