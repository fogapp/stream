# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Playback", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:user) { create_user(household: household) }

  def movie_with(fixture, name: "Heat (1995)/Heat.#{File.extname(fixture).delete('.')}")
    root = build_root(name => fixture)
    library = create_library(household: household, roots: root)
    file = MediaFile.create!(household: household, library: library, path: File.join(root, name), size: File.size(media_fixture(fixture)),
      mtime: Time.current, state: "probed")
    Media::FileProber.new(file).call
    movie = Movie.create!(household: household, library: library, title: "Heat", year: 1995)
    movie.editions.create!(media_file: file)
    movie
  end

  def play(movie, headers: {})
    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id },
      headers: auth_headers(user).merge(headers)
  end

  before { require_ffprobe! }

  it "direct-plays an MP4, serving the bytes with Range support behind a stream token" do
    movie = movie_with("h264_aac.mp4")
    play(movie)

    expect(response).to have_http_status(:created)
    expect(json).to include("method" => "direct", "resume_at" => 0.0)
    expect(json["source"]).to include("mime_type" => "video/mp4", "url" => %r{\A/media/s/[^/]+/original\.mp4\z})
    expect(json.dig("media_file", "audio").sole).to include("codec" => "aac")

    get json.dig("source", "url"), headers: { "Range" => "bytes=0-99" }
    expect(response).to have_http_status(:partial_content)
    expect(response.body.bytesize).to eq(100)
    expect(response.headers["Content-Range"]).to start_with("bytes 0-99/")
  end

  it "tells the player when the file's share can't keep up with it" do
    movie = movie_with("h264_aac.mp4")
    play(movie)
    expect(json).to include("falls_behind" => false)

    file = movie.editions.sole.media_file
    allow(Playback::ShareSpeed).to receive(:read).and_return(Playback::Pace.bitrate_of(file) / 4)
    play(movie)
    expect(json).to include("falls_behind" => true)
  end

  it "plays an extra, and its page shows it with the version's edition name" do
    movie = movie_with("h264_aac.mp4")
    movie.editions.sole.update!(name: "Director's Cut")
    path = File.join(build_root("Heat-trailer.mp4" => "h264_aac.mp4"), "Heat-trailer.mp4")
    file = MediaFile.create!(household: household, library: movie.library, path: path, size: File.size(path), mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(file).call
    trailer = Extra.create!(household: household, media_file: file, owner: movie, kind: "trailer", title: "Heat")

    get "/api/v1/movies/#{movie.id}", headers: auth_headers(user)
    expect(json["versions"].sole).to include("edition" => "Director's Cut")
    expect(json["extras"].sole).to include("id" => trailer.id, "kind" => "extra", "extra_kind" => "trailer", "kind_label" => "Trailer")

    post "/api/v1/playback_sessions", params: { playable_type: "extra", playable_id: trailer.id }, headers: auth_headers(user)
    expect(response).to have_http_status(:created)
    expect(json).to include("title" => "Heat", "subtitle" => "Trailer · Heat", "back_path" => "/movie/#{movie.id}", "next_up" => nil)
  end

  it "plays a channel video, with Back to its watch page" do
    path = File.join(build_root("TC/Talk [abcdefghijk].mp4" => "h264_aac.mp4"), "TC/Talk [abcdefghijk].mp4")
    library = create_library(household: household, roots: File.dirname(File.dirname(path)), kind: "channels")
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    Catalog::FileMatcher.new(file.reload).call
    video = Video.sole

    post "/api/v1/playback_sessions", params: { playable_type: "video", playable_id: video.id }, headers: auth_headers(user)
    expect(response).to have_http_status(:created)
    expect(json).to include("title" => "Talk", "subtitle" => "TC", "back_path" => "/video/#{video.id}")
  end

  it "counts what each media request sends, for Stats' measured bitrate" do
    movie = movie_with("h264_aac.mp4")
    play(movie)
    url = json.dig("source", "url")
    get url, headers: { "Range" => "bytes=0-99" }
    get url, headers: { "Range" => "bytes=-50" }
    get url
    session = PlaybackSession.sole
    size = File.size(session.media_file.path)
    expect(session.bytes_sent).to eq(100 + 50 + size)

    session.update!(started_at: 2.minutes.ago, last_seen_at: Time.current)
    row = Stats::Watching.session_json(session.reload)
    expect(row).to include(bitrate_measured: true, bytes_sent: 150 + size)
    expect(row[:bitrate_kbps]).to eq(((150 + size) * 8 / 120.0 / 1000).round)
  end

  it "answers with X-Sendfile for Thruster when configured to, whatever the request says" do
    movie = movie_with("h264_aac.mp4")
    play(movie)
    url = json.dig("source", "url")

    # Not configured (development, specs): a client's header changes nothing.
    get url, headers: { "X-Sendfile-Type" => "X-Accel-Redirect" }
    expect(response.headers["X-Sendfile"]).to be_nil
    expect(response.body.bytesize).to eq(File.size(media_fixture("h264_aac.mp4")))

    # Configured (production): Thruster is told which file, and sends it.
    expect_sent_by_thruster(url, movie.media_files.sole.path)
  end

  describe "streaming" do
    def chrome_caps
      { "hls" => "mse", "containers" => %w[mp4 webm], "video" => %w[h264 vp9 av1], "audio" => %w[aac opus],
        "max_audio_channels" => 2, "hdr" => [], "max_height" => 1080 }
    end

    before do
      @cache = Dir.mktmpdir("stream-cache")
      stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
      @supervisor = Playback::Supervisor.new(encoder: Playback::Encoders::Kind::Software, log: ->(_) { })
      allow(Playback::Signal).to receive(:request) { |session_id, gop| @supervisor.request(session_id, gop) }
      @publishing = publish_runs { @supervisor }
    end

    after do
      @publishing.kill
      @supervisor.stop_all
      FileUtils.rm_rf(@cache)
    end

    def stream(movie, caps: chrome_caps, **extra)
      post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id, device_key: "laptop-1",
        capabilities: caps }.merge(extra), headers: auth_headers(user).merge("User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Chrome/140.0 Safari/537.36"),
        as: :json
    end

    it "streams an MKV as HLS: playlist, init and segments, with the reason recorded" do
      stream(movie_with("h264_aac_ac3_subs.mkv"))

      expect(response).to have_http_status(:created)
      expect(json["method"]).to eq("remux")
      expect(json["source"]).to include("kind" => "hls", "url" => %r{/hls/index\.m3u8\z})
      expect(PlaybackSession.find(json["id"]).segment_target_ms).to eq(2000)
      expect(json.dig("decision", "summary")).to eq("Chrome on macOS can't open MKV files — repackaged, no quality loss")

      base = json.dig("source", "url").delete_suffix("index.m3u8")
      get json.dig("source", "url")
      expect(response.media_type).to eq("application/vnd.apple.mpegurl")
      expect(response.body).to include("seg-0.m4s")
      get "#{base}init.mp4"
      expect(response).to have_http_status(:ok)
      get "#{base}seg-0.m4s"
      expect(response).to have_http_status(:ok)
      expect(response.body.bytesize).to be_positive
      session = PlaybackSession.sole
      expect_sent_by_thruster("#{base}init.mp4", Playback::Cache.init(session.id))
      expect_sent_by_thruster("#{base}seg-0.m4s", Playback::Cache.directory(session.id, 0).join("seg-0.m4s"))
    end

    # A viewer flicking past a title closes its session while its init is
    # still being made: nothing went wrong, so no 5xx and no error recorded.
    it "lets go of a stream whose session ended, without calling it an error" do
      stream(movie_with("h264_aac_ac3_subs.mkv"))
      base = json.dig("source", "url").delete_suffix("index.m3u8")
      session = PlaybackSession.sole
      # Closed while the request waits on the transcoder.
      allow(Playback::Signal).to receive(:request) { session.end! }

      get "#{base}init.mp4"
      expect(response).to have_http_status(:gone)
      expect(PlaybackEvent.where(playback_session: session, kind: "error")).to be_empty
    end

    # The transcoder's sweep can take a stopped run's segments between
    # Segments finding one and send_file reading it: made again, not a 500.
    it "makes a segment again when the cache is swept from under it" do
      stream(movie_with("h264_aac_ac3_subs.mkv"))
      base = json.dig("source", "url").delete_suffix("index.m3u8")
      session = PlaybackSession.sole
      sweeps = 0
      allow_any_instance_of(Playback::Segments).to receive(:segment).and_wrap_original do |original, *args|
        original.call(*args).tap do
          sweeps += 1
          next if sweeps.even?

          @supervisor.stop(session.id)
          FileUtils.rm_rf(Playback::Cache.directory(session.id))
        end
      end

      get "#{base}seg-0.m4s"
      expect(response).to have_http_status(:ok)
      expect(response.body.bytesize).to be_positive
      expect_sent_by_thruster("#{base}seg-0.m4s", Playback::Cache.directory(session.id, 0).join("seg-0.m4s"))
      expect(sweeps).to eq(4)
    end

    # CLAUDE.md invariant 4: ffprobe ran at scan time; choosing how to play
    # reads rows. The one tool a play may start is the keyframe scan for a
    # file the background index hasn't reached yet.
    it "decides and starts a stream from rows, running no tool once the file is indexed" do
      movie = movie_with("h264_aac_ac3_subs.mkv")
      Media::KeyframeIndex.store(movie.media_files.sole, [ 0, 2000, 4000 ], Media::KeyframeIndex::Source::Packets)
      allow(ToolRunner).to receive(:run).and_call_original

      stream(movie)

      expect(response).to have_http_status(:created)
      expect(ToolRunner).not_to have_received(:run)
    end

    # The packet scan reads the whole
    # file, so a press of Play never waits on it — it's queued where nothing
    # pauses it, and this play converts; the next repackages.
    it "converts a file with no index of its own this time, and queues its scan" do
      movie = movie_with("h264_aac_ac3_subs.mkv")
      file = movie.media_files.sole
      allow(Media::KeyframeIndex).to receive(:from_container).and_return(nil)
      allow(Media::Keyframes::PacketScan).to receive(:keyframes_ms)

      expect { stream(movie) }.to have_enqueued_job(IndexKeyframesJob).with(file.id, true).on_queue("index").at_priority(-10)
      expect(response).to have_http_status(:created)
      expect(json["method"]).to eq("video_transcode")
      expect(json.dig("decision", "summary")).to eq(Playback::Start::INDEXING_REASON)
      expect(response.headers["Retry-After"]).to be_nil
      expect(Media::Keyframes::PacketScan).not_to have_received(:keyframes_ms)

      # Asking again queues nothing more while the scan is on its way.
      expect { stream(movie) }.not_to have_enqueued_job(IndexKeyframesJob)

      Media::KeyframeIndex.store(file.reload, [ 0, 2000 ], Media::KeyframeIndex::Source::Packets)
      stream(movie)
      expect(json["method"]).to eq("remux")
    end

    it "converts a file whose scan couldn't be done, and doesn't scan it again" do
      movie = movie_with("h264_aac_ac3_subs.mkv")
      file = movie.media_files.sole
      Media::KeyframeIndex.store(file, [], Media::KeyframeIndex::Source::None)
      expect { stream(movie) }.not_to have_enqueued_job(IndexKeyframesJob)
      expect(json["method"]).to eq("video_transcode")
    end

    it "reads a container's own keyframe index on the spot, and records doing it" do
      movie = movie_with("h264_aac_ac3_subs.mkv")
      stream(movie)
      expect(response).to have_http_status(:created)
      file = movie.media_files.sole.reload
      expect(file.keyframes).to be_present
      expect(AnalysisRun.find_by!(media_file: file, step: "keyframes")).to have_attributes(status: "succeeded", tool_version: "container-index")
    end

    it "asks nothing about transcoders for a stream that only repackages" do
      allow(Playback::Placement).to receive(:node_for_video).and_call_original
      stream(movie_with("h264_aac_ac3_subs.mkv"))
      expect(response).to have_http_status(:created)
      expect(Playback::Placement).not_to have_received(:node_for_video)
    end

    it "keeps a stream's segments in the browser, and counts their bytes with the next touch" do
      stream(movie_with("h264_aac_ac3_subs.mkv"))
      playlist = json.dig("source", "url")
      base = playlist.delete_suffix("index.m3u8")
      session = PlaybackSession.sole
      get "#{base}init.mp4"
      expect(response.headers["Cache-Control"]).to eq("max-age=21600, private, immutable")
      get "#{base}seg-0.m4s"
      expect(response.headers["Cache-Control"]).to eq("max-age=21600, private, immutable")
      sent = File.size(Playback::Cache.init(session.id)) + File.size(Playback::Cache.directory(session.id, 0).join("seg-0.m4s"))
      expect(session.reload.bytes_sent + Playback::BytesSent::PENDING.fetch(session.id, 0)).to eq(sent)

      session.update_columns(last_seen_at: 1.minute.ago)
      get playlist
      expect(session.reload.bytes_sent).to eq(sent)
      expect(Playback::BytesSent::PENDING.fetch(session.id, 0)).to eq(0)
    end

    it "offers smaller versions only off the household's network, or when the browser asks" do
      movie = movie_with("h264_aac_ac3_subs.mkv")
      adaptive = -> { PlaybackSession.find(json["id"]).adaptive }
      stream(movie)
      expect(adaptive.call).to be(false)
      stream(movie, abr: true)
      expect(adaptive.call).to be(true)
      post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id, capabilities: chrome_caps },
        headers: auth_headers(user), env: { "REMOTE_ADDR" => "203.0.113.9" }, as: :json
      expect(adaptive.call).to be(true)
    end

    it "remembers the device and its profile" do
      stream(movie_with("h264_aac.mp4"))
      expect(Device.sole).to have_attributes(client_key: "laptop-1", name: "Chrome on macOS")
      expect(Device.sole.capabilities["video"]).to eq(%w[h264 vp9 av1])
      expect(PlaybackSession.sole.device).to eq(Device.sole)
    end

    it "leaves the device's row alone when nothing about it changed" do
      movie = movie_with("h264_aac.mp4")
      stream(movie)
      written = Device.sole.updated_at
      travel 1.minute do
        stream(movie)
        expect(Device.sole.updated_at).to eq(written)
      end
      travel 10.minutes do
        stream(movie)
        expect(Device.sole.last_seen_at).to be_within(1.second).of(Time.current)
      end
    end

    # The fixtures are tiny; the rows say full HD, which is all the
    # decision engine reads (CLAUDE.md invariant 4).
    def full_hd(movie)
      movie.media_files.sole.media_streams.where(kind: "video").update_all(width: 1920, height: 1080)
      movie
    end

    it "converts smaller past the cap, and refuses only when even that won't fit" do
      # The default cap depends on the CPU (AVX2 allows two); pin it at one.
      allow(Playback::Encoders).to receive(:avx2?).and_return(false)
      movie = full_hd(movie_with("hevc_main10_hdr10.mkv"))
      stream(movie)
      expect(json["method"]).to eq("video_transcode")
      expect(json.dig("decision", "video", "height")).to eq(1080)

      # A full slot in use: 720p (0.44 of one) doesn't fit either.
      stream(movie)
      expect(response).to have_http_status(:conflict)
      expect(json["errors"].join).to include("already being converted")

      # At 720p the first leaves room for another 720p (0.44 each)…
      PlaybackSession.update_all("decision = jsonb_set(decision, '{video,height}', '720')")
      stream(movie)
      expect(response).to have_http_status(:created)
      expect(json.dig("decision", "video", "height")).to eq(720)
      expect(PlaybackSession.order(:created_at).last.decision["reasons"].last).to include("Smaller than it could be")

      # …and with 0.72 in use, only 480p (0.2) still fits.
      PlaybackSession.update_all("decision = jsonb_set(decision, '{video,height}', '612')")
      stream(movie)
      expect(json.dig("decision", "video", "height")).to eq(480)
    end

    it "refuses plainly when the browser can't stream" do
      stream(movie_with("h264_aac_ac3_subs.mkv"), caps: chrome_caps.merge("hls" => "none"))
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].join).to include("can't play streamed video")
    end

    it "switches audio track by starting a new session at the given position" do
      stream(movie_with("h264_aac_ac3_subs.mkv"), audio_index: 2, start: 1.0)
      expect(json).to include("audio_stream_index" => 2, "resume_at" => 1.0)
      expect(json.dig("decision", "audio")).to include("codec" => "aac", "copy" => false)
    end

    it "records stalls and errors the player reports" do
      stream(movie_with("h264_aac.mp4"))
      post json["events_url"], params: { events: [ { kind: "stall", position: 12.5, detail: { seconds: 2.1 } },
        { kind: "recovery", position: 14.0, detail: { message: "bufferSeekOverHole", count: 3, cause: "PIPELINE_ERROR_DECODE", anything: "else" } },
        { kind: "bogus" } ] }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(PlaybackEvent.where(kind: "stall").sole).to have_attributes(position_seconds: 12.5, detail: { "seconds" => 2.1 })
      expect(PlaybackEvent.where(kind: "recovery").sole.detail).to eq("message" => "bufferSeekOverHole", "cause" => "PIPELINE_ERROR_DECODE", "count" => 3)
    end

    it "records how long starting and seeking took, and where the time went" do
      stream(movie_with("h264_aac.mp4"))
      post json["events_url"], params: { events: [
        { kind: "startup", position: 0, detail: { ms: 640, session_ms: 90, manifest_ms: 120, init_ms: 300, fragment_ms: 520, frame_ms: 640,
                                                 cookie: "no" } },
        { kind: "seek", position: 80, detail: { ms: 210, ready: false } }
      ] }, as: :json
      expect(PlaybackEvent.where(kind: "startup").sole.detail).to eq(
        "ms" => 640, "session_ms" => 90, "manifest_ms" => 120, "init_ms" => 300, "fragment_ms" => 520, "frame_ms" => 640
      )
      expect(PlaybackEvent.where(kind: "seek").sole.detail).to eq("ms" => 210, "ready" => false)
    end

    it "records a native player's totals when its play ends" do
      stream(movie_with("h264_aac.mp4"))
      session_id = json["id"]
      post json["events_url"], params: { events: [
        { kind: "summary", position: 1290.5, detail: { ms: 1820, stalls: 2, dropped_frames: 7, watched_seconds: 1288, bitrate: 4_210_000, extra: 1 } }
      ] }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(PlaybackEvent.where(kind: "summary").sole).to have_attributes(position_seconds: 1290.5,
        detail: { "ms" => 1820, "stalls" => 2, "dropped_frames" => 7, "watched_seconds" => 1288, "bitrate" => 4_210_000 })
      get "/api/v1/playback_decisions/#{session_id}", headers: auth_headers(create_user(household: household, role: "admin"))
      message = response.parsed_body.fetch("events").find { |event| event["kind"] == "summary" }.fetch("message")
      expect(message).to eq("2 stalls, 7 dropped frames, 21 min watched at 4.2 Mb/s, started in 1820 ms")
    end

    it "says where a press of Play spent its time, for the browser's network panel" do
      stream(movie_with("h264_aac_ac3_subs.mkv"))
      expect(response.headers["Server-Timing"]).to include("decide.stream", "keyframes.stream", "serialize.stream")
    end
  end

  it "refuses forged, ended and foreign tokens" do
    movie = movie_with("h264_aac.mp4")
    play(movie)
    url = json.dig("source", "url")
    session_id = json["id"]

    get url.sub(%r{/s/[^.]+\.}, "/s/#{SecureRandom.uuid}.")
    expect(response).to have_http_status(:not_found)

    # Foreign: a token that isn't a stream token at all — a download's, for a
    # row of this very movie.
    download = OfflineDownload.create!(household: household, profile: PlaybackSession.find(session_id).profile, playable: movie,
      media_file: movie.media_files.sole, size: 1, expires_at: 1.day.from_now)
    get url.sub(%r{/s/[^/]+/}, "/s/#{Playback::DownloadToken.issue(download)}/")
    expect(response).to have_http_status(:not_found)

    # Other people can't end a session that isn't theirs.
    delete "/api/v1/playback_sessions/#{session_id}", headers: auth_headers(create_user(household: create_household(name: "Other")))
    expect(response).to have_http_status(:not_found)
    get url
    expect(response).to have_http_status(:ok)

    delete "/api/v1/playback_sessions/#{session_id}", headers: auth_headers(user)
    get url
    expect(response).to have_http_status(:not_found)
  end

  it "won't play another household's movie" do
    movie = movie_with("h264_aac.mp4")
    stranger = create_user(household: create_household(name: "Other"))
    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id }, headers: auth_headers(stranger)
    expect(response).to have_http_status(:not_found)
  end

  describe "progress" do
    let(:movie) { movie_with("h264_aac.mp4") }

    # The fixture is two seconds long; stretch it so the thresholds mean something.
    before do
      play(movie)
      @progress_url = json["progress_url"]
      MediaFile.update_all(duration_seconds: 3600)
    end

    it "keeps a resume point once past two minutes, and resumes there next time" do
      post @progress_url, params: { position: 60 }, as: :json
      expect(WatchState.sole.position_seconds).to eq(0)

      post @progress_url, params: { position: 1800 }, as: :json
      expect(json).to eq("position_seconds" => 1800.0, "completed" => false)

      play(movie)
      expect(json["resume_at"]).to eq(1800.0)
    end

    it "counts a play once at 90%, however many reports arrive through the credits" do
      post @progress_url, params: { position: 3300 }, as: :json
      post @progress_url, params: { position: 3500 }, as: :json

      expect(WatchState.sole).to have_attributes(play_count: 1, position_seconds: 0, completed_at: be_present)

      play(movie)
      post json["progress_url"], params: { position: 3400 }, as: :json
      expect(WatchState.sole.play_count).to eq(2)
    end

    it "takes sendBeacon's text/plain body when the tab closes" do
      post @progress_url, params: { position: 900, ended: true }.to_json, headers: { "Content-Type" => "text/plain" }
      expect(WatchState.sole.position_seconds).to eq(900)
      expect(PlaybackSession.sole.state).to eq("ended")
    end
  end

  it "watches as the named profile, and falls back to the default for a foreign one" do
    movie = movie_with("h264_aac.mp4")
    kids = Profile.create!(household: household, name: "Kids")
    play(movie, headers: profile_header(kids))
    expect(json["profile_id"]).to eq(kids.id)

    foreign = Profile.create!(household: create_household(name: "Other"), name: "Them")
    play(movie, headers: profile_header(foreign))
    expect(json["profile_id"]).to eq(Profile.default_for(household).id)
  end

  describe "readable" do
    def readable(type, id)
      get "/api/v1/playback_sessions/readable", params: { playable_type: type, playable_id: id }, headers: auth_headers(user)
    end

    it "says a title with a probed file can be resumed" do
      movie = movie_with("h264_aac.mp4")
      readable("movie", movie.id)
      expect(response).to have_http_status(:ok)
      expect(json).to eq("readable" => true)
    end

    it "says a title whose files have all gone can't be, and a purged one isn't found" do
      movie = movie_with("h264_aac.mp4")
      movie.media_files.update_all(state: "missing") # rubocop:disable Rails/SkipsModelValidations
      readable("movie", movie.id)
      expect(json).to eq("readable" => false)

      id = movie.id
      movie.destroy!
      readable("movie", id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
