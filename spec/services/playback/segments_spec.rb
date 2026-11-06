# typed: false
# frozen_string_literal: true

require "rails_helper"

# Waiting for the transcoder holds a Puma thread, so the wait ends as soon
# as nothing will come of it — including when the session is let go (a
# channel changed away from) while a segment request is still waiting.
RSpec.describe Playback::Segments do
  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    # No transcoder: nothing is ever made.
    allow(Playback::Signal).to receive(:request)
  end

  after { FileUtils.rm_rf(@cache) }

  let(:household) { Household.create!(name: "Stream") }
  let(:chrome) { Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac]) }
  let(:session) do
    root = build_root("Heat/Heat.mkv" => "h264_aac_ac3_subs.mkv")
    library = create_library(household: household, roots: root)
    path = File.join(root, "Heat/Heat.mkv")
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    Media::KeyframeIndex.store(file.reload, [ 0 ], Media::KeyframeIndex::Source::Packets)
    decision = Playback::Decision.new(file, chrome)
    movie = Movie.create!(household: household, library: library, title: "Heat")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file.reload,
      method: decision.method.serialize, decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current)
  end

  it "counts an init as ready only once a fragment beside it says ffmpeg finished it" do
    directory = Playback::Cache.directory(session.id)
    FileUtils.mkdir_p(directory)
    File.binwrite(Playback::Cache.init(session.id), "moov, half written")
    expect(Playback::Cache.init_ready?(session.id)).to be(false)
    File.binwrite(directory.join("gop-0.m4s"), "moof")
    expect(Playback::Cache.init_ready?(session.id)).to be(true)
  end

  it "keeps a built plan until the file's keyframe index changes" do
    first = Playback::SegmentPlan.for(session)
    expect(Playback::SegmentPlan.for(session)).to equal(first)
    Media::KeyframeIndex.store(session.media_file.reload, [ 0, 7000 ], Media::KeyframeIndex::Source::Packets)
    rebuilt = Playback::SegmentPlan.for(session)
    expect(rebuilt).not_to equal(first)
    expect(rebuilt.gop_starts).to eq([ 0, 7000 ])
  end

  it "stops waiting for a segment as soon as whoever asked has hung up" do
    gone = false
    web = described_class.new(session, gone: -> { gone })
    waiting = Thread.new { web.segment(0) }
    waiting.report_on_exception = false
    sleep 0.2
    expect(waiting).to be_alive
    gone = true
    expect { waiting.value }.to raise_error(described_class::Abandoned)
  end

  it "stops waiting for a segment once its session has ended" do
    expect(session.method_enum).to eq(PlaybackSession::Method::Remux)
    session.end!
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { described_class.new(session).segment(0) }.to raise_error(described_class::Ended, "the session ended")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end
end
