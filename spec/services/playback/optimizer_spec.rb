# typed: false
# frozen_string_literal: true

require "rails_helper"

# Optimized versions encoded for real (PROPOSAL §5.5): the transcoder's
# optimizer claims one, runs ffmpeg in the background, and leaves an
# H.264/AAC MP4 any browser plays — or, when it has to stop, puts it back
# in the queue without calling it a failure.
RSpec.describe Playback::Optimizer do
  include ActiveSupport::Testing::TimeHelpers

  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    AppSetting.current.update!(optimize_quiet_start_hour: 0, optimize_quiet_end_hour: 0)
  end

  after do
    optimizer.stop
    FileUtils.rm_rf(@cache)
  end

  let(:optimizer) { described_class.new(encoder: Playback::Encoders::Kind::Software, worker: "spec", log: ->(_) { }) }
  let(:household) { Household.create!(name: "Stream") }

  def probed_file(fixture)
    root = build_root(fixture => fixture)
    library = create_library(household: household, roots: root)
    path = File.join(root, fixture)
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(file).call
    file.reload
  end

  def queue(file, **attributes)
    OptimizedVersion.create!(household: household, media_file: file, **attributes)
  end

  def tick_until(timeout: 90, busy: false)
    deadline = Time.current + timeout
    loop do
      optimizer.tick(busy: busy)
      return if yield
      raise "timed out" if Time.current > deadline

      sleep 0.2
    end
  end

  it "encodes HDR HEVC into an H.264 SDR MP4 with stereo AAC and records the analysis step" do
    file = probed_file("hevc_main10_hdr10.mkv")
    version = queue(file)

    tick_until { version.reload.state_enum != OptimizedVersion::State::Queued && optimizer.job.nil? }

    expect(version).to have_attributes(state_enum: OptimizedVersion::State::Ready, progress: 1.0, worker: nil, attempts: 1,
      encoder: "software")
    expect(version.size).to eq(version.path.size)
    expect(version.partial_path).not_to exist
    probe = JSON.parse(ToolRunner.run(%W[ffprobe -v error -show_streams -show_format -of json #{version.path}]).stdout)
    video = probe["streams"].find { |stream| stream["codec_type"] == "video" }
    audio = probe["streams"].find { |stream| stream["codec_type"] == "audio" }
    expect(video).to include("codec_name" => "h264", "pix_fmt" => "yuv420p")
    expect(video["height"]).to eq(version.height)
    expect(audio).to include("codec_name" => "aac", "channels" => 2) if file.media_streams.any? { |s| s.kind == "audio" }
    expect(probe.dig("format", "format_name")).to include("mp4")

    run = AnalysisRun.find_by(media_file: file, step: "optimize")
    expect(run).to have_attributes(status_enum: AnalysisRun::Status::Succeeded, error: nil)
    expect(Dir.children(OptimizedVersion.root)).to eq([ "#{version.id}.mp4" ])
  end

  it "waits for quiet hours unless an admin said now, and puts admins' requests first" do
    # Noon on the household's clock, quiet hours overnight.
    travel_to Time.zone.parse("2026-09-27 12:00")
    AppSetting.current.update!(optimize_quiet_start_hour: 1, optimize_quiet_end_hour: 6)
    AppSetting.bust_cache!
    automatic = queue(probed_file("h264_hi10p.mkv"))
    optimizer.tick(busy: false)
    expect(optimizer.job).to be_nil

    manual = queue(probed_file("mpeg2_mp2.ts"), origin: "manual", run_now: true)
    optimizer.tick(busy: false)
    expect(optimizer.job&.version_id).to eq(manual.id)
    expect(automatic.reload.state_enum).to eq(OptimizedVersion::State::Queued)
  end

  # docs/PERF_PROPOSAL.md › P20: an airing tonight, or the next episode,
  # before whatever has merely been waiting longest.
  it "takes the soonest needed before the oldest queued" do
    waiting = queue(probed_file("h264_hi10p.mkv"))
    later = queue(probed_file("mpeg2_mp2.ts"), needed_at: 2.days.from_now)
    soonest = queue(probed_file("hevc_main10_hdr10.mkv"), needed_at: 3.hours.from_now)
    optimizer.tick(busy: false)
    expect(optimizer.job&.version_id).to eq(soonest.id)
    expect([ waiting, later ].map { |version| version.reload.state }).to all(eq("queued"))
  end

  it "gives way to a live conversion without counting it as an attempt" do
    file = probed_file("hevc_main10_hdr10.mkv")
    version = queue(file)
    optimizer.tick(busy: false)
    expect(version.reload.state_enum).to eq(OptimizedVersion::State::Encoding)

    optimizer.tick(busy: true)
    expect(optimizer.job).to be_nil
    expect(version.reload).to have_attributes(state_enum: OptimizedVersion::State::Queued, attempts: 0, progress: 0.0, worker: nil,
      interruptions: 1, interruption: "someone started watching something that needs converting")
    expect(version.interrupted_at).to be_within(5.seconds).of(Time.current)
    expect(version.partial_path).not_to exist
    expect(AnalysisRun.find_by(media_file: file, step: "optimize").status_enum).to eq(AnalysisRun::Status::Pending)
  end

  describe "how long an encode may take" do
    before do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      Playback::ShareSpeed.forget!
    end

    after { Playback::ShareSpeed.forget! }

    def remux_on(speed)
      file = probed_file("h264_aac.mp4")
      file.update!(size: 126.gigabytes)
      Playback::ShareSpeed.record(Playback::Pace.root_of(file), speed) if speed
      file
    end

    it "gives a remux on a slow share its reading time and half as much again" do
      file = remux_on(2_800_000.0)
      expect(described_class.timeout_for(file)).to be_within(1).of(126.gigabytes / 2_800_000.0 * 1.5)
      expect(described_class.timeout_for(file)).to be > described_class::TIMEOUT.to_f
    end

    it "keeps the usual limit on a fast share or an unmeasured one, and never goes past the longest" do
      expect(described_class.timeout_for(remux_on(nil))).to eq(described_class::TIMEOUT.to_f)
      Playback::ShareSpeed.forget!
      expect(described_class.timeout_for(remux_on(90_000_000.0))).to eq(described_class::TIMEOUT.to_f)
      Playback::ShareSpeed.forget!
      expect(described_class.timeout_for(remux_on(1_000.0))).to eq(described_class::LONGEST.to_f)
    end
  end

  it "stops when the version is deleted" do
    version = queue(probed_file("hevc_main10_hdr10.mkv"))
    optimizer.tick(busy: false)
    version.destroy!
    optimizer.tick(busy: false)
    expect(optimizer.job).to be_nil
  end

  it "records a failed encode, retries it, and gives up after three attempts" do
    file = probed_file("h264_aac.mp4")
    File.write(file.path, "not a video any more")
    settle_library_roots!
    version = queue(file)

    3.times do |attempt|
      tick_until { optimizer.job.nil? && version.reload.attempts == attempt + 1 && version.state_enum != OptimizedVersion::State::Encoding }
    end
    expect(version.reload).to have_attributes(state_enum: OptimizedVersion::State::Failed, attempts: 3)
    expect(version.error).to start_with("ffmpeg exited")
    run = AnalysisRun.find_by(media_file: file, step: "optimize")
    expect(run).to have_attributes(status_enum: AnalysisRun::Status::Failed, consecutive_failures: 3)
  end

  it "takes back an encode whose transcoder went quiet" do
    version = queue(probed_file("h264_hi10p.mkv"), state: "encoding", worker: "gone", heartbeat_at: 10.minutes.ago)

    # Busy with a live conversion: it takes the encode back but starts nothing.
    # The attempt stands: the encode may be what took its transcoder down.
    optimizer.tick(busy: true)
    expect(version.reload).to have_attributes(state_enum: OptimizedVersion::State::Queued, worker: nil, interruptions: 1,
      interruption: "gone stopped answering", attempts: 0)

    optimizer.tick(busy: false)
    expect(version.reload).to have_attributes(state_enum: OptimizedVersion::State::Encoding, worker: "spec")
  end

  it "takes the one an admin said to do next ahead of everything else" do
    asked = queue(probed_file("h264_hi10p.mkv"), origin: "manual")
    soonest = queue(probed_file("mpeg2_mp2.ts"), needed_at: 1.hour.from_now)
    nxt = queue(probed_file("hevc_main10_hdr10.mkv"))
    soonest.prioritize!
    nxt.prioritize!
    expect(OptimizedVersion.queued.in_queue_order.map(&:id)).to eq([ nxt.id, soonest.id, asked.id ])

    optimizer.tick(busy: false)
    expect(optimizer.job&.version_id).to eq(nxt.id)
  end

  it "starts only what an admin said to do now while paused, and stops the rest" do
    waiting = queue(probed_file("hevc_main10_hdr10.mkv"))
    optimizer.tick(busy: false)
    expect(waiting.reload.state_enum).to eq(OptimizedVersion::State::Encoding)

    AppSetting.current.update!(optimize_paused: true)
    AppSetting.bust_cache!
    optimizer.tick(busy: false)
    expect(waiting.reload).to have_attributes(state_enum: OptimizedVersion::State::Queued, interruption: "optimizing was paused")

    optimizer.tick(busy: false)
    expect(optimizer.job).to be_nil

    now = queue(probed_file("mpeg2_mp2.ts"), origin: "manual", run_now: true)
    optimizer.tick(busy: false)
    expect(optimizer.job&.version_id).to eq(now.id)
  end

  it "stops an encode that an admin said not to make" do
    version = queue(probed_file("hevc_main10_hdr10.mkv"))
    optimizer.tick(busy: false)
    version.reload.skip!
    optimizer.tick(busy: false)
    expect(optimizer.job).to be_nil
    expect(version.reload.state_enum).to eq(OptimizedVersion::State::Skipped)
  end
end
