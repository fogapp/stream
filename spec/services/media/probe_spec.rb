# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Media::Probe do
  before { require_ffprobe! }

  def stream(result, index) = result.streams.find { |s| s[:index] == index }

  it "normalizes every track of a multi-track MKV into MediaStream columns" do
    result = described_class.run(media_fixture("h264_aac_ac3_subs.mkv"))

    expect(result.container).to include("matroska")
    expect(result.duration_seconds).to be_within(0.2).of(2.0)
    expect(result.streams.map { |s| s[:kind] }).to eq(%w[video audio audio subtitle subtitle])
    expect(stream(result, 0)).to include(codec: "h264", width: 160, height: 90, bit_depth: 8, frame_rate: 24.0)
    expect(stream(result, 2)).to include(codec: "ac3", channels: 6, language: "eng", title: "Surround 5.1")
    expect(stream(result, 4)).to include(codec: "ass", language: "jpn", forced: true)
  end

  it "recognizes HDR10 and 10-bit video" do
    video = stream(described_class.run(media_fixture("hevc_main10_hdr10.mkv")), 0)
    expect(video).to include(codec: "hevc", profile: "Main 10", bit_depth: 10, hdr_format: "hdr10",
      color_transfer: "smpte2084")
  end

  it "leaves SDR video without an HDR format" do
    expect(stream(described_class.run(media_fixture("h264_aac.mp4")), 0)[:hdr_format]).to be_nil
  end

  # A file cut short plays up to where
  # it ends, as it does in Plex and Jellyfin.
  it "keeps a truncated file, saying it ends early" do
    result = described_class.run(media_fixture("truncated.mkv"))
    expect(result.streams).not_to be_empty
    expect(result.warning).to start_with("The file ends early")
  end

  it "raises a readable error for a file that isn't a video at all" do
    path = File.join(Dir.mktmpdir("probe"), "noise.mkv")
    File.binwrite(path, Random.new(1).bytes(64 * 1024))
    expect { described_class.run(path) }.to raise_error(described_class::Error)
  end

  it "keeps what decisions need: chroma, sound's rate, interlacing, rotation" do
    plain = described_class.run(media_fixture("h264_aac.mp4"))
    expect(stream(plain, 0)).to include(chroma: "420", field_order: "progressive", rotation: nil, codec_tag: "avc1")
    expect(stream(plain, 1)[:sample_rate]).to be_positive

    made = Dir.mktmpdir("probe")
    interlaced = File.join(made, "interlaced.ts")
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=25:duration=1 -c:v libx264 -preset ultrafast
      -flags +ildct+ilme -x264-params tff=1 -pix_fmt yuv422p #{interlaced}])
    picture = stream(described_class.run(interlaced), 0)
    expect(picture).to include(chroma: "422", field_order: "tt")

    rotated = File.join(made, "rotated.mp4")
    ToolRunner.run(%W[ffmpeg -v error -y -display_rotation 90 -i #{media_fixture('h264_aac.mp4')} -c copy #{rotated}])
    expect(stream(described_class.run(rotated), 0)[:rotation].abs).to eq(90)
  end
end
