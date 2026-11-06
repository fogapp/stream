# typed: false
# frozen_string_literal: true

require "rails_helper"

# Every whole-file step from one read: four passes over a 137 GB remux at
# the 6 MB/s its share manages was a day of reading; one is six hours.
RSpec.describe Media::OnePass do
  before do
    require_ffprobe!
    @storage = Dir.mktmpdir("stream-storage")
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => @storage))
  end

  after { FileUtils.rm_rf(@storage) }

  let(:household) { Household.create!(name: "One") }

  def probed(fixture, name = fixture)
    root = build_root(name => fixture)
    library = create_library(household: household, roots: root)
    file = MediaFile.create!(household: household, library: library, path: File.join(root, name), size: File.size(media_fixture(fixture)),
      mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    file.reload
  end

  def ffmpeg_runs
    runs = []
    allow(ToolRunner).to receive(:each_line).and_wrap_original { |m, argv, **kw, &blk| runs << argv; m.call(argv, **kw, &blk) }
    allow(ToolRunner).to receive(:run_advancing).and_wrap_original { |m, argv, **kw| runs << argv; m.call(argv, **kw) }
    runs
  end

  it "makes the thumbnails, the keyframe index, the loudness and the subtitles from one read, then has nothing to do" do
    file = probed("h264_aac_ac3_subs.mkv")
    file.update!(keyframes: nil, keyframes_source: nil)
    runs = ffmpeg_runs

    expect(described_class.run(file)).to match_array([ AnalysisRun::Step::Trickplay, AnalysisRun::Step::Keyframes,
      AnalysisRun::Step::Loudness, AnalysisRun::Step::Subtitles ])

    expect(runs.size).to eq(1)
    argv = runs.sole
    expect(argv.count("-i")).to eq(1)
    expect(argv).to include(*Media::OnePass::KEYFRAMES_ONLY)
    expect(argv).not_to include("-progress")
    file.reload
    expect(file.trickplay).to have_attributes(version: 1, sheet_count: 1)
    expect(file.trickplay.sheet(0)).to be_file
    expect(file).to have_attributes(keyframes: [ 0, 500, 1000, 1500 ], keyframes_source: "packets")
    expect(file.loudness_lufs).to be_within(1).of(-21.8)
    expect(file.true_peak_dbfs).to be_within(1).of(-17.6)
    expect(Dir.children(Subtitles::Extractor.root.join(file.id)).sort).to eq(%w[e3.vtt e4.ass e4.vtt])
    expect(file.analysis_runs.where(step: %w[trickplay keyframes loudness subtitles]).pluck(:status).uniq).to eq([ "succeeded" ])
    expect(file.analysis_runs.find_by(step: "trickplay").tool_version).to start_with("ffmpeg ")

    expect(described_class.needed?(file)).to be(false)
    expect(described_class.run(file)).to eq([])
    expect(runs.size).to eq(1)
  end

  # The decoder sees exactly the packets the scan would flag: the index is
  # the same, and the container's own, however it's found.
  it "indexes keyframes from the decode the way the packet scan reads them" do
    %w[vp9_opus.webm av1_opus.webm hevc_main10_hdr10.mkv h264_aac.mp4 mpeg2_mp2.ts].each do |fixture|
      file = probed(fixture)
      scanned = Media::Keyframes::PacketScan.keyframes_ms(file.path, stream: file.primary_video.index)
      file.update!(keyframes: nil, keyframes_source: nil)

      described_class.run(file)

      expect(file.reload.keyframes).to eq(scanned), fixture
    end
  end

  it "leaves the keyframe index alone when the file has one, and never redoes it for a failed run" do
    file = probed("h264_aac_ac3_subs.mkv")
    IndexKeyframesJob.perform_now(file.id)
    expect(file.reload.keyframes_source).to eq("cues")
    file.analysis_runs.find_by!(step: "keyframes").update!(status: "failed", error: "x")
    runs = ffmpeg_runs

    described_class.run(file)

    expect(described_class.parts_for(file).map(&:step)).not_to include(AnalysisRun::Step::Keyframes)
    expect(file.reload.keyframes_source).to eq("cues")
    expect(file.analysis_runs.find_by(step: "keyframes").status).to eq("failed")
  end

  it "measures the loudness again without decoding the picture, keeping time by -progress" do
    file = probed("h264_aac_ac3_subs.mkv")
    described_class.run(file)
    Analysis::Rerun.call(file, AnalysisRun::Step::Loudness)
    runs = ffmpeg_runs

    expect(described_class.run(file.reload)).to eq([ AnalysisRun::Step::Loudness ])

    argv = runs.sole
    expect(argv).to include("-progress", "pipe:1", "ebur128=peak=true:framelog=quiet")
    expect(argv).not_to include("-skip_frame", "-filter_complex", "[sheets]")
    expect(argv.each_cons(Media::OnePass::PACE_OUTPUT.size)).not_to include(Media::OnePass::PACE_OUTPUT) # the loudness output moves with the read
    expect(file.reload.trickplay.version).to eq(1)
  end

  it "paces a read of subtitles alone by the audio" do
    file = probed("h264_aac_ac3_subs.mkv")
    described_class.run(file)
    Analysis::Rerun.call(file, AnalysisRun::Step::Subtitles)
    runs = ffmpeg_runs

    expect(described_class.run(file.reload)).to eq([ AnalysisRun::Step::Subtitles ])

    expect(runs.sole.each_cons(Media::OnePass::PACE_OUTPUT.size)).to include(Media::OnePass::PACE_OUTPUT)
    expect(Dir.children(Subtitles::Extractor.root.join(file.id)).sort).to eq(%w[e3.vtt e4.ass e4.vtt])
  end

  it "records a damaged file's keyframes as none to be had, and finishes the rest" do
    file = probed("mpeg2_mp2.ts")
    file.update!(keyframes: nil, keyframes_source: nil)
    # What the probe said before the file went bad: the keyframes stop far short of it.
    allow(Media::Keyframes::PacketScan).to receive(:complete!).and_wrap_original { |m, times, **| m.call(times, duration_seconds: 1300.0) }

    expect(described_class.run(file)).to match_array([ AnalysisRun::Step::Trickplay, AnalysisRun::Step::Loudness, AnalysisRun::Step::Subtitles ])

    expect(file.reload).to have_attributes(keyframes_source: "none", keyframes: [])
    expect(file.analysis_runs.find_by(step: "keyframes")).to have_attributes(status: "failed", error: a_string_including("Incomplete"))
    expect(file.analysis_runs.find_by(step: "loudness").status).to eq("succeeded")
  end

  it "records which step failed, keeps what the others made, and raises for the job to try again" do
    file = probed("h264_aac_ac3_subs.mkv")
    allow(Media::Loudness).to receive(:parse).and_return(nil)

    expect { described_class.run(file) }.to raise_error(ToolRunner::Error, /no loudness/)

    expect(file.reload.analysis_runs.find_by(step: "loudness")).to have_attributes(status: "failed", consecutive_failures: 1)
    expect(file.analysis_runs.find_by(step: "trickplay").status).to eq("succeeded")
    expect(file.trickplay.sheet(0)).to be_file
    expect(described_class.parts_for(file).map(&:step)).to eq([ AnalysisRun::Step::Loudness ])
  end

  # One output's failure fails the read, so it mustn't fail the next one
  # too: the part is left out until asked for again, and says why.
  it "lays a failure at the output's door, leaves that part out of the next read, and takes it back on a rerun" do
    file = probed("h264_aac_ac3_subs.mkv")
    IndexKeyframesJob.perform_now(file.id)
    # A directory nothing made: ffmpeg can't open the subtitle outputs.
    allow(Subtitles::Extractor).to receive(:path_for).and_wrap_original { |m, *args| m.call(*args).dirname.join("gone", m.call(*args).basename) }

    expect { described_class.run(file) }.to raise_error(Media::OnePass::ReadFailed)
    runs = file.reload.analysis_runs.index_by(&:step)
    expect(runs["subtitles"].error).to start_with("Media::OnePass::OutputError:")
    expect(runs["trickplay"].error).to include("the read failed on subtitles's output")
    expect(described_class.parts_for(file).map(&:step)).not_to include(AnalysisRun::Step::Subtitles)

    allow(Subtitles::Extractor).to receive(:path_for).and_call_original
    expect(described_class.run(file)).to match_array([ AnalysisRun::Step::Trickplay, AnalysisRun::Step::Loudness ])

    Analysis::Rerun.call(file, AnalysisRun::Step::Subtitles)
    expect(described_class.run(file.reload)).to eq([ AnalysisRun::Step::Subtitles ])
  end

  it "stops the read while someone is watching, and goes on when they're not" do
    file = probed("h264_aac_ac3_subs.mkv")
    holding = true
    Thread.new { sleep 1.5; holding = false }
    stub_const("ToolRunner::HOLD_POLL", 1)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.run(file, hold: -> { holding })

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be > 1.5
    expect(file.reload.trickplay.sheet(0)).to be_file
  end

  describe ".exclusively" do
    # Transactional examples share one connection across threads, and a
    # session's advisory lock is its own to take twice — so the lock is
    # played, not taken, here; Postgres keeps it between sessions.
    it "takes a lock on the file for the block, and gives it back" do
      file = probed("h264_aac_ac3_subs.mkv")
      connection = ActiveRecord::Base.lease_connection
      allow(connection).to receive(:select_value).and_call_original

      expect(described_class.exclusively(file) { :read }).to eq(:read)

      expect(connection).to have_received(:select_value).with(a_string_matching(/pg_try_advisory_lock/)).ordered
      expect(connection).to have_received(:select_value).with(a_string_matching(/pg_advisory_unlock/)).ordered
    end

    it "runs nothing when another read of the file holds it" do
      file = probed("h264_aac_ac3_subs.mkv")
      allow(ActiveRecord::Base.lease_connection).to receive(:select_value).with(a_string_matching(/pg_try_advisory_lock/)).and_return(false)

      expect(described_class.exclusively(file) { raise "ran" }).to be_nil
    end

    it "has the job look again later" do
      file = probed("h264_aac_ac3_subs.mkv")
      allow(described_class).to receive(:exclusively).and_return(nil)

      AnalyzeMediaFileJob.perform_now(file.id)

      expect(AnalyzeMediaFileJob).to have_been_enqueued.with(file.id)
    end
  end
end
