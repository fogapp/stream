# typed: false
# frozen_string_literal: true

require "rails_helper"

# The container readers are only worth having if they say exactly what the
# packet scan says (PROPOSAL §5.3). Every case here checks one against the
# other.
RSpec.describe "Keyframe index" do
  before { require_ffprobe! }

  def scan(path) = Media::Keyframes::PacketScan.keyframes_ms(path)

  describe "on the fixture corpus" do
    %w[h264_aac.mp4 h264_aac_movtext.mp4].each do |name|
      it "reads #{name}'s stss the way ffprobe reads its packets" do
        path = media_fixture(name)
        expect(Media::Keyframes::Mp4.new(path).keyframes_ms).to eq(scan(path))
      end
    end

    %w[h264_aac_ac3_subs.mkv hevc_main10_hdr10.mkv vp9_opus.webm av1_opus.webm h264_dts.mkv].each do |name|
      it "reads #{name}'s Cues the way ffprobe reads its packets" do
        path = media_fixture(name)
        expect(Media::Keyframes::Matroska.new(path).keyframes_ms).to eq(scan(path))
      end
    end
  end

  describe "on longer files with irregular GOPs" do
    # 20 s, keyframes forced every 3.7 s, B-frames on: what a real encode's
    # scene-cut keyframes and composition offsets look like. The MP4 keeps
    # its moov at the end (no faststart), as many rips do.
    before(:context) do
      @dir = Dir.mktmpdir("keyframes")
      base = %w[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=24:duration=20 -c:v libx264 -preset ultrafast
        -bf 3 -g 1000 -force_key_frames expr:gte(t,n_forced*3.7)]
      @mp4 = File.join(@dir, "long.mp4")
      @mkv = File.join(@dir, "long.mkv")
      ToolRunner.run(base + [ @mp4 ])
      ToolRunner.run(base + [ @mkv ])
    end

    after(:context) { FileUtils.rm_rf(@dir) }

    it "agrees on an MP4 with its index at the end" do
      expected = scan(@mp4)
      expect(expected.size).to be >= 5
      expect(Media::Keyframes::Mp4.new(@mp4).keyframes_ms).to eq(expected)
    end

    it "agrees on an MKV" do
      expect(Media::Keyframes::Matroska.new(@mkv).keyframes_ms).to eq(scan(@mkv))
    end
  end

  it "gives up on what it can't read exactly, rather than guessing" do
    expect(Media::Keyframes::Mp4.new(media_fixture("h264_aac_ac3_subs.mkv")).keyframes_ms).to be_nil
    expect(Media::Keyframes::Matroska.new(media_fixture("h264_aac.mp4")).keyframes_ms).to be_nil
    expect(Media::Keyframes::Matroska.new(media_fixture("truncated.mkv")).keyframes_ms).to be_nil
  end

  describe IndexKeyframesJob do
    let(:household) { Household.create!(name: "K") }

    def probed(fixture, name)
      root = build_root(name => fixture)
      library = create_library(household: household, roots: root)
      file = MediaFile.create!(household: household, library: library, path: File.join(root, name), size: File.size(media_fixture(fixture)),
        mtime: Time.current, state: "discovered")
      Media::FileProber.new(file).call
      file.reload
    end

    it "stores the container index and records the step" do
      file = probed("h264_aac_ac3_subs.mkv", "a.mkv")
      described_class.perform_now(file.id)

      expect(file.reload).to have_attributes(keyframes: [ 0, 500, 1000, 1500 ], keyframes_source: "cues")
      expect(file.analysis_runs.find_by(step: "keyframes")).to have_attributes(status: "succeeded", tool_version: "container-index")
      expect(enqueued_jobs).to be_empty
    end

    it "hands a file with no container index to the heavy queue, which scans its packets" do
      file = probed("mpeg2_mp2.ts", "old.ts")
      described_class.perform_now(file.id)

      scan_job = enqueued_jobs.sole
      expect(scan_job).to include("queue_name" => "heavy", "arguments" => [ file.id, true ])

      described_class.perform_now(file.id, true)
      expect(file.reload.keyframes_source).to eq("packets")
      expect(file.keyframes.first).to be_a(Integer)
    end

    it "does nothing with a scan for a file indexed meanwhile (by the one read over it)" do
      file = probed("mpeg2_mp2.ts", "old.ts")
      file.update!(keyframes: [ 0, 1234 ], keyframes_source: "packets")
      expect(ToolRunner).not_to receive(:each_line)

      described_class.perform_now(file.id, true)

      expect(file.reload.keyframes).to eq([ 0, 1234 ])
    end

    it "fails a scan whose keyframes stop well short of the runtime, leaves it for Needs attention, and doesn't scan it again" do
      file = probed("mpeg2_mp2.ts", "damaged.ts")
      file.update!(duration_seconds: 1300.0) # what the probe said before the file went bad

      described_class.perform_now(file.id, true)

      # No index to be had: plays convert it.
      expect(file.reload).to have_attributes(keyframes_source: "none", keyframes: [])
      expect(Media::KeyframeIndex.usable?(file)).to be(false)
      expect(file.analysis_runs.find_by(step: "keyframes")).to have_attributes(status: "failed",
        error: a_string_including("PacketScan::Incomplete"))
      expect(enqueued_jobs).to be_empty
    end
  end
end
