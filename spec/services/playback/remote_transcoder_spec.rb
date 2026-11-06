# typed: false
# frozen_string_literal: true

require "rails_helper"
require "puma"
require "puma/server"
load Rails.root.join("bin/stream-transcode-worker").to_s

# A remote transcoder end to end (PROPOSAL §11 Phase 6): Stream served by a
# real Puma, bin/stream-transcode-worker polling it from a thread, and real
# ffmpeg on both sides. The worker reads the original over the signed URL
# and uploads fragments; the web side joins them into segments exactly as
# it does for the local transcoder. On a Mac the worker finds VideoToolbox,
# so this covers that encoder too; in CI it's software.
RSpec.describe "Remote transcoder" do
  before do
    require_ffprobe!
    # The worker really talks HTTP, to the Puma below and nothing else.
    WebMock.disable_net_connect!(allow_localhost: true)
    @cache = Dir.mktmpdir("stream-cache")
    @work = Dir.mktmpdir("stream-worker")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::Signal).to receive(:request) { |session_id, gop| supervisor.request(session_id, gop) }

    # For a run that ends up here rather than on the node.
    @publishing = publish_runs { supervisor }

    @server = Puma::Server.new(Rails.application, nil, min_threads: 1, max_threads: 4, log_writer: Puma::LogWriter.null)
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run

    generated = TranscodeNode.generate(name: "Mac mini")
    @node = generated.node
    @worker = StreamWorker::Worker.new(server: "http://127.0.0.1:#{@port}", token: generated.token, work_dir: @work, ffmpeg: "ffmpeg",
      log: StringIO.new)
    @worker_thread = Thread.new { @worker.run }
    wait_for { @node.reload.online? && @node.encoder.present? }
  end

  after do
    @publishing.kill
    supervisor.stop_all
    @worker&.stop!
    @worker_thread&.join(10)
    @server&.stop(true)
    WebMock.disable_net_connect!(allow_localhost: false)
    FileUtils.rm_rf([ @cache, @work ])
  end

  let(:supervisor) { Playback::Supervisor.new(encoder: Playback::Encoders::Kind::Software, log: ->(_) { }) }
  let(:household) { Household.create!(name: "Stream") }
  let(:chrome) do
    Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac], "max_audio_channels" => 2)
  end

  def wait_for(timeout: 30)
    deadline = Time.current + timeout
    until yield
      raise "timed out" if Time.current > deadline

      sleep 0.1
    end
  end

  def probed(fixture)
    root = build_root(fixture => fixture)
    library = create_library(household: household, roots: root)
    path = File.join(root, fixture)
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(file).call
    file.reload
  end

  def session_on_node(fixture)
    file = probed(fixture)
    times, source = Media::KeyframeIndex.from_container(file)
    Media::KeyframeIndex.store(file, times || Media::Keyframes::PacketScan.keyframes_ms(file.path),
      source || Media::KeyframeIndex::Source::Packets)
    decision = Playback::Decision.new(file, chrome, max_height: 2160)
    movie = Movie.create!(household: household, library: file.library, title: "T")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file,
      method: decision.method.serialize, decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current,
      transcode_node: @node)
  end

  def stream_file(session)
    web = Playback::Segments.new(session)
    out = File.join(@cache, "joined-#{SecureRandom.hex(3)}.mp4")
    File.open(out, "wb") do |file|
      file.write(File.binread(web.init))
      web.plan.segments.each_index { |index| file.write(File.binread(web.segment(index))) }
    end
    out
  end

  def streams_of(path)
    JSON.parse(ToolRunner.run(%W[ffprobe -v error -show_streams -of json #{path}]).stdout)["streams"]
  end

  it "introduces itself with what its machine can encode" do
    # Whatever this machine has, named the way Stream knows it; only a Mac
    # has VideoToolbox.
    possible = RUBY_PLATFORM.include?("darwin") ? %w[videotoolbox software] : %w[vaapi software]
    expect(possible).to include(@node.encoder)
    expect(@node.capabilities).to include("worker" => StreamWorker::VERSION, "hostname" => Socket.gethostname)
    expect(@node.capabilities["filters"]).to include("scale")
  end

  it "converts a session's video there, and the web side serves segments from what it uploads" do
    session = session_on_node("h264_hi10p.mkv")
    expect(session.method_enum).to eq(PlaybackSession::Method::VideoTranscode)

    joined = stream_file(session)
    run = TranscodeRun.find_by(playback_session: session)
    expect(run).to have_attributes(transcode_node_id: @node.id)
    source = run.argv.index("{server}/media/n/#{Playback::RunToken.issue(run)}/source")
    expect(source).not_to be_nil
    # A dropped read picks up where it was, and the option comes before -i.
    expect(run.argv.index("-reconnect")).to be < source
    video = streams_of(joined).find { |stream| stream["codec_type"] == "video" }
    expect(video).to include("codec_name" => "h264", "pix_fmt" => "yuv420p")
    expect(ToolRunner.run(%W[ffmpeg -v error -i #{joined} -f null -]).stderr).to eq("")

    supervisor.stop(session.id)
    wait_for { run.reload.state_enum == TranscodeRun::State::Exited }
    # The row closes as it's stopped; the worker hears at its next poll.
    wait_for { Dir.children(@work).empty? }
  end

  it "tone-maps an HDR session there, on the media engine when the node is a Mac" do
    session = session_on_node("hevc_main10_hdr10.mkv")
    expect(session.decision.dig("video", "tonemap")).to be(true)
    expect(@node.encoder).to eq("videotoolbox") if RUBY_PLATFORM.include?("darwin")

    joined = stream_file(session)
    run = TranscodeRun.find_by(playback_session: session)
    expect(run.argv.join(" ")).to include("scale_vt") if @node.encoder == "videotoolbox"
    video = streams_of(joined).find { |stream| stream["codec_type"] == "video" }
    expect(video).to include("codec_name" => "h264", "pix_fmt" => "yuv420p")
    expect(video).to include("color_transfer" => "bt709") if @node.encoder == "videotoolbox"
  end

  it "carries a session on here when its transcoder goes quiet" do
    session = session_on_node("h264_aac_ac3_subs.mkv")
    @worker.stop!
    @worker_thread.join(10)
    @node.update!(last_seen_at: 1.minute.ago)

    joined = stream_file(session)
    expect(session.reload.transcode_node_id).to be_nil
    expect(supervisor.runs.fetch(session.id).handle.remote?).to be(false)
    expect(File.size(joined)).to be_positive
  end

  it "encodes an optimized version there when it's idle" do
    AppSetting.current.update!(optimize_quiet_start_hour: 0, optimize_quiet_end_hour: 0)
    file = probed("hevc_main10_hdr10.mkv")
    version = OptimizedVersion.create!(household: household, media_file: file)
    optimizer = Playback::Optimizer.new(encoder: Playback::Encoders::Kind::Software, worker: "fog", log: ->(_) { })

    optimizer.tick(busy: false)
    expect(version.reload).to have_attributes(state_enum: OptimizedVersion::State::Encoding, worker: "Mac mini", encoder: @node.encoder)
    wait_for(timeout: 90) do
      optimizer.tick(busy: false)
      version.reload.state_enum != OptimizedVersion::State::Encoding
    end

    expect(version).to have_attributes(state_enum: OptimizedVersion::State::Ready, error: nil)
    expect(streams_of(version.path.to_s).find { |stream| stream["codec_type"] == "video" }).to include("codec_name" => "h264")
  end
end
