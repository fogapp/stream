# typed: false
# frozen_string_literal: true

require "rails_helper"

# How a remote run ends without an exit code: nothing here spawns ffmpeg, the
# polls are made by hand, so each ending can be set up exactly.
RSpec.describe "Remote runs that end badly" do
  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::Signal).to receive(:ready)
  end

  after { FileUtils.rm_rf(@cache) }

  let(:supervisor) { Playback::Supervisor.new(encoder: Playback::Encoders::Kind::Software, log: ->(_) { }) }
  let(:household) { Household.create!(name: "Stream") }
  let(:node) { TranscodeNode.generate(name: "Mac mini").node.tap { |made| made.update!(last_seen_at: Time.current, encoder: "software") } }
  let(:caps) do
    Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac], "max_audio_channels" => 2)
  end

  let(:session) do
    root = build_root("h264_hi10p.mkv" => "h264_hi10p.mkv")
    library = create_library(household: household, roots: root)
    path = File.join(root, "h264_hi10p.mkv")
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    file.reload
    times, source = Media::KeyframeIndex.from_container(file)
    Media::KeyframeIndex.store(file, times || Media::Keyframes::PacketScan.keyframes_ms(path), source || Media::KeyframeIndex::Source::Packets)
    decision = Playback::Decision.new(file, caps, max_height: 2160)
    movie = Movie.create!(household: household, library: library, title: "T")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file,
      method: decision.method.serialize, decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current, transcode_node: node)
  end

  def report(running: [], exited: []) = Playback::NodeLink.parse("running" => running, "exited" => exited)

  # The worker's next poll, which takes up what's pending.
  def handed_out
    Playback::NodeLink.poll(node, report)
    TranscodeRun.where(playback_session: session).order(:created_at).last
  end

  it "records a run killed on its node as crashed, starts it again, and gives up on the second" do
    supervisor.request(session.id, 0)
    first = handed_out
    Playback::NodeLink.poll(node, report(exited: [ { "id" => first.id, "status" => nil, "log" => "Killed" } ]))
    supervisor.tick

    expect(first.reload).to have_attributes(failure: "crashed")
    second = handed_out
    expect(second.id).not_to eq(first.id)
    expect(supervisor.runs.fetch(session.id).handle.run_id).to eq(second.id)

    Playback::NodeLink.poll(node, report(exited: [ { "id" => second.id, "status" => nil, "log" => "Killed" } ]))
    supervisor.tick

    expect(second.reload).to have_attributes(failure: "crashed")
    expect(session.reload.transcode_error).to start_with("ffmpeg was killed on its transcoder")
    expect(supervisor.runs).to be_empty
  end

  it "records a run its worker lost track of, and starts it again" do
    supervisor.request(session.id, 0)
    first = handed_out
    first.update!(started_at: 1.minute.ago)
    Playback::NodeLink.poll(node, report)
    supervisor.tick

    expect(first.reload).to have_attributes(failure: "lost", log_tail: "Mac mini lost track of this run")
    expect(handed_out.id).not_to eq(first.id)
  end

  it "doesn't try a refused run again, and leaves the session's error standing" do
    supervisor.request(session.id, 0)
    run = handed_out
    Playback::NodeLink.send(:refuse, run, session, "the plan's GOP 1 isn't a keyframe")
    expect(run.reload).to have_attributes(failure: "refused", state: "stopping")
    Playback::NodeLink.poll(node, report)
    supervisor.tick

    supervisor.request(session.id, 1)

    expect(supervisor.runs).to be_empty
    expect(TranscodeRun.where(playback_session: session).count).to eq(1)
    expect(session.reload.transcode_error).to start_with("The stream's fragments weren't what was planned")
    expect(ActivityEntry.where(event: "transcode.failed").count).to eq(1)
  end

  it "says nothing of a run stopped on purpose" do
    supervisor.request(session.id, 0)
    run = handed_out
    supervisor.stop(session.id)
    Playback::NodeLink.poll(node, report)
    supervisor.tick

    expect(run.reload).to have_attributes(state: "exited", failure: nil)
    expect(session.reload.transcode_error).to be_nil
  end

  it "says nothing of a run whose row has gone" do
    supervisor.request(session.id, 0)
    handed_out.destroy!
    supervisor.tick

    expect(supervisor.runs).to be_empty
    expect(session.reload.transcode_error).to be_nil
  end
end
