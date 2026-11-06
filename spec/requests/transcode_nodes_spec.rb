# typed: false
# frozen_string_literal: true

require "rails_helper"

# Remote transcoders from the outside (PROPOSAL §11 Phase 6): admins add
# and tune them; a worker's polls move its runs along; its uploads land only
# where its own runs write; the source URL opens only while a run is live.
RSpec.describe "Transcode nodes", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }

  before do
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
  end

  after { FileUtils.rm_rf([ @cache, *Dir.glob(File.join(Dir.tmpdir, "stream-made*")) ]) }

  def add_node(name = "Mac mini")
    post "/api/v1/transcode_nodes", params: { name: name }, headers: auth_headers(admin)
    [ TranscodeNode.find(json["id"]), json["token"] ]
  end

  def poll(token, body = {})
    post "/api/v1/transcoder/poll", params: body.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    json
  end

  def session_run(node)
    root = build_root("Heat.mkv" => "h264_aac_ac3_subs.mkv")
    library = create_library(household: household, roots: root)
    file = MediaFile.create!(household: household, library: library, path: File.join(root, "Heat.mkv"), size: 1, mtime: Time.current,
      state: "probed", duration_seconds: 2.0)
    movie = Movie.create!(household: household, library: library, title: "Heat")
    session = PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file,
      method: "remux", decision: {}, started_at: Time.current, last_seen_at: Time.current, transcode_node: node)
    TranscodeRun.create!(transcode_node: node, playback_session: session, argv: %w[ffmpeg -version])
  end

  it "adds one for an admin, showing its token once, and keeps members out" do
    post "/api/v1/transcode_nodes", params: { name: "Mac mini" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)

    node, token = add_node
    expect(token).to start_with("streamnode_")
    expect(node.token_digest).to eq(TranscodeNode.digest(token))

    get "/api/v1/transcode_nodes", headers: auth_headers(admin)
    expect(json["nodes"].sole).to include("name" => "Mac mini", "online" => false, "token_prefix" => token.first(17))
    expect(json["nodes"].sole).not_to have_key("token")

    patch "/api/v1/transcode_nodes/#{node.id}", params: { max_sessions: 3, optimize: false }, headers: auth_headers(admin)
    expect(json).to include("max_sessions" => 3, "optimize" => false)
    patch "/api/v1/transcode_nodes/#{node.id}", params: { max_sessions: 9 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "introduces a worker, hands it pending runs, stops what's stopping and notices what it lost" do
    node, token = add_node
    poll(token, "hello" => { "encoder" => "videotoolbox", "hostname" => "mini.lan", "worker" => "1", "filters" => %w[scale zscale tonemap] })
    expect(node.reload).to have_attributes(encoder: "videotoolbox", online?: true)
    expect(node.profile.tonemap_filter).to start_with("zscale")
    expect(Playback::Placement.capacity).to eq(Playback::Encoders.cap + 2)

    run = session_run(node)
    answer = poll(token)
    expect(answer["start"].sole).to include("id" => run.id, "argv" => %w[ffmpeg -version], "kind" => "session")
    expect(run.reload.state_enum).to eq(TranscodeRun::State::Running)
    expect(poll(token, "running" => [ run.id ])["start"]).to be_empty

    Playback::Runner.kill(Playback::Runner::RemoteHandle.new(run_id: run.id, node_id: node.id))
    expect(poll(token, "running" => [ run.id ])["stop"]).to eq([ run.id ])
    poll(token, "exited" => [ { "id" => run.id, "status" => nil, "log" => "" } ])
    expect(run.reload).to have_attributes(state_enum: TranscodeRun::State::Exited, exit_status: nil)

    # A run the worker still has that isn't live here (lost, or from before
    # a restart) is stopped.
    expect(poll(token, "running" => [ run.id ])["stop"]).to eq([ run.id ])

    lost = session_run(node)
    poll(token)
    lost.update!(started_at: 1.minute.ago)
    poll(token, "running" => [])
    expect(lost.reload).to have_attributes(state_enum: TranscodeRun::State::Exited, log_tail: "Mac mini lost track of this run")
  end

  it "asks little of an idle poll, and still keeps the node online" do
    node, token = add_node
    poll(token, "hello" => { "encoder" => "videotoolbox" })
    report = Playback::NodeLink.parse({})

    node = TranscodeNode.find(node.id)
    expect(count_queries { Playback::NodeLink.poll(node, report) }.size).to eq(1)

    node.update!(last_seen_at: 1.minute.ago)
    Playback::NodeLink.poll(node, report)
    expect(node.reload.online?).to be(true)
  end

  it "takes a run's fragments into its session's cache, and nothing else" do
    node, token = add_node
    run = session_run(node)
    headers = { "Authorization" => "Bearer #{token}", "Content-Type" => "application/octet-stream" }

    # What its ffmpeg would write: an init segment and the film's one GOP.
    require_ffprobe!
    made = Dir.mktmpdir("stream-made")
    ToolRunner.run(%W[ffmpeg -v error -y -i #{run.playback_session.media_file.path} -map 0:v:0 -map 0:a:0 -c copy -copyts -avoid_negative_ts disabled
      -f hls -hls_time 0.001 -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 -hls_segment_options movflags=+frag_discont
      -start_number 3 -hls_segment_filename #{made}/gop-%d.m4s -hls_list_size 0 #{made}/run.m3u8])
    run.update!(state: "running", started_at: Time.current)
    session_id = run.playback_session_id
    published = -> { Playback::Cache.directory(session_id).children.select(&:file?).map { |path| path.basename.to_s }.sort }

    # A fragment with no init segment to read it by is refused, and says so.
    put "/api/v1/transcoder/runs/#{run.id}/files/gop-3.m4s", params: File.binread("#{made}/gop-3.m4s"), headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(run.reload.state_enum).to eq(TranscodeRun::State::Stopping)
    expect(run.playback_session.reload.transcode_error).to start_with("The stream's fragments weren't what was planned")
    expect(published.call).to be_empty
    run.update!(state: "running")

    put "/api/v1/transcoder/runs/#{run.id}/files/init.mp4", params: File.binread("#{made}/init.mp4"), headers: headers
    expect(response).to have_http_status(:no_content)
    # The film is one 2 s GOP of the plan, four keyframes long: each upload
    # is kept until it's whole, and then published under the GOP it holds —
    # the film's first — whatever the worker called it.
    fragments = (3..6).map { |number| "gop-#{number}.m4s" }
    fragments.each_with_index do |name, index|
      expect(published.call).to eq(%w[init.mp4]), "published before #{name}"
      put "/api/v1/transcoder/runs/#{run.id}/files/#{name}", params: File.binread("#{made}/#{name}"), headers: headers
      expect(response).to have_http_status(:no_content)
      expect(index).to eq(fragments.size - 1) if published.call.include?("gop-0.m4s")
    end
    expect(published.call).to eq(%w[gop-0.m4s init.mp4])
    expect(Playback::Cache.gop(session_id, 0).binread).to eq(fragments.map { |name| File.binread("#{made}/#{name}") }.join)

    # Not a fragment at all.
    put "/api/v1/transcoder/runs/#{run.id}/files/gop-4.m4s", params: "fragment", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    run.update!(state: "running")

    put "/api/v1/transcoder/runs/#{run.id}/files/output.mp4", params: "x", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    put "/api/v1/transcoder/runs/#{run.id}/files/..%2Fescape.m4s", params: "x", headers: headers
    expect(response).to have_http_status(:not_found) # the route takes no slash, escaped or not
    # A name the route allows but isn't a fragment: the target is built from
    # a whitelist, never from what the node sent.
    put "/api/v1/transcoder/runs/#{run.id}/files/..gop-4.m4s", params: "x", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(published.call).to eq(%w[gop-0.m4s init.mp4])

    other, other_token = add_node("Other")
    put "/api/v1/transcoder/runs/#{run.id}/files/gop-4.m4s", params: "x",
      headers: headers.merge("Authorization" => "Bearer #{other_token}")
    expect(response).to have_http_status(:not_found)
    expect(other).to be_persisted

    put "/api/v1/transcoder/runs/#{run.id}/files/gop-4.m4s", params: "x", headers: headers.merge("Authorization" => "Bearer nope")
    expect(response).to have_http_status(:unauthorized)
  end

  it "serves the original to a live run's token only" do
    node, = add_node
    run = session_run(node)
    token = Playback::RunToken.issue(run)

    get "/media/n/#{token}/source", headers: { "Range" => "bytes=0-9" }
    expect(response).to have_http_status(:partial_content)
    expect(response.body.bytesize).to eq(10)
    expect_sent_by_thruster("/media/n/#{token}/source", run.playback_session.media_file.path)

    get "/media/n/#{run.id}.forged/source"
    expect(response).to have_http_status(:not_found)
    run.exited!(0)
    get "/media/n/#{token}/source"
    expect(response).to have_http_status(:not_found)
  end

  it "hands out the worker script to anyone" do
    get "/api/v1/transcoder/worker"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("module StreamWorker")
  end
end
