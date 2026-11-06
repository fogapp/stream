# typed: false
# frozen_string_literal: true

require "rails_helper"
require "open3"

# fog-compute/1 end to end (fog:docs/compute-contract.md): Stream on a real
# Puma, and fog's whole compute path — the relay polling Stream as its pool,
# the data route, the fog-node runner with this machine's ffmpeg — run from
# a fog checkout by its e2e harness. Nothing here is a stand-in for fog.
# Opt-in: it needs Go and the fog repo (FOG_REPO, default ../fog), and a
# machine whose ffmpeg has a hardware encoder for fog to pool.
RSpec.describe "fog's transcoders, end to end" do
  fog_repo = File.expand_path(ENV.fetch("FOG_REPO", File.join(__dir__, "../../../../fog")))
  go = [ "/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/bin/go" ].find { |path| File.executable?(path) }
  runnable = go && File.exist?(File.join(fog_repo, "internal/compute/e2eharness/main.go")) && RUBY_PLATFORM.include?("darwin")

  before do
    skip "needs Go, a fog checkout (FOG_REPO) and a Mac's VideoToolbox" unless runnable
    require_ffprobe!
    WebMock.disable_net_connect!(allow_localhost: true)
    @cache = Dir.mktmpdir("stream-cache")
    @token = "fog-e2e-#{SecureRandom.hex(8)}"
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache, "FOG_API_TOKEN" => @token))
    allow(Playback::Signal).to receive(:request) { |session_id, gop| supervisor.request(session_id, gop) }
    @publishing = publish_runs { supervisor }

    @server = Puma::Server.new(Rails.application, nil, min_threads: 2, max_threads: 8, log_writer: Puma::LogWriter.null)
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run

    env = { "APP_URL" => "http://127.0.0.1:#{@port}", "FOG_API_TOKEN" => @token, "PATH" => "#{File.dirname(go)}:#{ENV.fetch('PATH', '')}" }
    @fog_in, @fog_out, @fog_wait = Open3.popen2e(env, go, "run", "-tags", "e2e", "./internal/compute/e2eharness", chdir: fog_repo)
    @fog_log = +""
    @fog_reader = Thread.new { @fog_out.each_line { |line| @fog_log << line } }
    wait_for(timeout: 180) { @fog_log.include?("ready ") || !@fog_wait.alive? }
    raise "fog's harness didn't start:\n#{@fog_log}" unless @fog_wait.alive?

    wait_for(timeout: 30) { TranscodeNode.fog.first&.online? }
    @node = TranscodeNode.fog.sole
  end

  after do
    @publishing&.kill
    supervisor.stop_all
    if @fog_wait&.alive?
      Process.kill("TERM", @fog_wait.pid)
      @fog_wait.join(15) || Process.kill("KILL", @fog_wait.pid)
    end
    @server&.stop(true)
    WebMock.disable_net_connect!(allow_localhost: false)
    FileUtils.rm_rf(@cache) if @cache
  end

  let(:supervisor) { Playback::Supervisor.new(encoder: Playback::Encoders::Kind::Software, log: ->(_) { }) }
  let(:household) { Household.create!(name: "Stream") }
  let(:chrome) do
    Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac], "max_audio_channels" => 2)
  end

  def wait_for(timeout: 30)
    deadline = Time.current + timeout
    until yield
      raise "timed out\n#{@fog_log}" if Time.current > deadline

      sleep 0.1
    end
  end

  def session_for(fixture)
    root = build_root(fixture => fixture)
    library = create_library(household: household, roots: root)
    path = File.join(root, fixture)
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    file.reload
    times, source = Media::KeyframeIndex.from_container(file)
    Media::KeyframeIndex.store(file, times || Media::Keyframes::PacketScan.keyframes_ms(file.path), source || Media::KeyframeIndex::Source::Packets)
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

  def video_of(path)
    JSON.parse(ToolRunner.run(%W[ffprobe -v error -show_streams -of json #{path}]).stdout)["streams"].find { |s| s["codec_type"] == "video" }
  end

  it "knows fog's pool as one transcoder, with the media engine's encoder and room" do
    expect(@node).to have_attributes(name: "fog · VideoToolbox", fog_pool: "video/videotoolbox", encoder: "videotoolbox")
    expect(@node.max_sessions).to be_positive
  end

  it "tone-maps an HDR session on fog's machine, and serves segments from what it uploaded" do
    session = session_for("hevc_main10_hdr10.mkv")
    joined = stream_file(session)
    run = TranscodeRun.find_by(playback_session: session)
    expect(run).to have_attributes(transcode_node_id: @node.id)
    expect(run.argv.join(" ")).to include("{server}/fog/compute/runs/", "scale_vt")
    expect(video_of(joined)).to include("codec_name" => "h264", "pix_fmt" => "yuv420p", "color_transfer" => "bt709")
    expect(ToolRunner.run(%W[ffmpeg -v error -i #{joined} -f null -]).stderr).to eq("")

    supervisor.stop(session.id)
    wait_for { run.reload.state_enum == TranscodeRun::State::Exited }
  end
end
