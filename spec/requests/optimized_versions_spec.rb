# typed: false
# frozen_string_literal: true

require "rails_helper"

# Optimized versions from the outside (PROPOSAL §5.5): asking for one,
# the queue, playing one where the original would convert, and the
# nightly pass that queues them on its own.
RSpec.describe "Optimized versions", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  # Chrome on a Mac: no HEVC.
  let(:chrome) do
    { "hls" => "mse", "containers" => %w[mp4 webm], "video" => %w[h264 vp9 av1], "audio" => %w[aac opus], "max_audio_channels" => 2,
      "max_height" => 2160 }
  end

  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
  end

  after { FileUtils.rm_rf(@cache) }

  def movie_with(fixture)
    root = build_root("Heat/Heat#{File.extname(fixture)}" => fixture)
    library = create_library(household: household, roots: root)
    path = File.join(root, "Heat/Heat#{File.extname(fixture)}")
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(file).call
    movie = Movie.create!(household: household, library: library, title: "Heat", year: 1995)
    movie.editions.create!(media_file: file)
    movie
  end

  def ready_version(file, bytes: "optimized bytes")
    version = OptimizedVersion.create!(household: household, media_file: file, state: "ready", height: 1080,
      audio_stream_index: file.media_streams.find { |stream| stream.kind == "audio" }&.index)
    FileUtils.mkdir_p(OptimizedVersion.root)
    File.binwrite(version.path, bytes)
    version.update!(size: bytes.bytesize)
    version
  end

  it "queues one for an admin, first in line and now if asked, and keeps members out" do
    file = movie_with("hevc_main10_hdr10.mkv").media_files.sole

    post "/api/v1/optimized_versions", params: { media_file_id: file.id }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)

    post "/api/v1/optimized_versions", params: { media_file_id: file.id, now: true }, headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    expect(json).to include("state" => "queued", "origin" => "manual", "run_now" => true)

    get "/api/v1/optimized_versions", headers: auth_headers(admin)
    expect(json["rows"].sole).to include("filename" => "Heat.mkv", "title" => "Heat 1995", "state" => "queued", "reason" => "manual",
      "queue_position" => 1, "fits_budget" => true)
    expect(json).to include("total" => 1)

    get "/api/v1/media_files/#{file.id}", headers: auth_headers(admin)
    expect(json["optimized"]).to include("state" => "queued")
    expect(json["analysis"].map { |run| run["step"] }).to include("optimize")
  end

  it "plays the optimized version where the original would convert, from the cache volume" do
    movie = movie_with("hevc_main10_hdr10.mkv")
    version = ready_version(movie.media_files.sole)

    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id, capabilities: chrome },
      headers: auth_headers(member)
    expect(response).to have_http_status(:created)
    expect(json).to include("method" => "optimized")
    expect(json["source"]).to include("kind" => "file", "mime_type" => "video/mp4", "url" => %r{/original\.mp4\z})
    expect(json.dig("decision", "summary")).to include("plays the optimized H.264 1080p version")

    url = json.dig("source", "url")
    get url
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("optimized bytes")

    # Deleted since: the stream answers not found, never the original.
    version.destroy!
    get url
    expect(response).to have_http_status(:not_found)
  end

  it "deletes one with its file" do
    file = movie_with("hevc_main10_hdr10.mkv").media_files.sole
    version = ready_version(file)
    delete "/api/v1/optimized_versions/#{version.id}", headers: auth_headers(admin)
    expect(response).to have_http_status(:no_content)
    expect(version.path).not_to exist
  end

  it "shows where each file in the transcode report stands" do
    file = movie_with("hevc_main10_hdr10.mkv").media_files.sole
    Device.create!(household: household, client_key: "chrome", name: "Chrome on Mac", capabilities: chrome, last_seen_at: Time.current)
    OptimizedVersion.create!(household: household, media_file: file, state: "encoding", progress: 0.4)

    get "/api/v1/playback_decisions/transcode_report", headers: auth_headers(admin)
    expect(json["rows"].sole).to include("media_file_id" => file.id, "all_devices" => true, "status" => "encoding")
    expect(json["rows"].sole["optimized"]).to include("state" => "encoding", "progress" => 0.4)
  end

  it "says what the optimizer is doing, and why not" do
    file = movie_with("hevc_main10_hdr10.mkv").media_files.sole
    OptimizedVersion.create!(household: household, media_file: file)

    get "/api/v1/optimized_versions/status", headers: auth_headers(admin)
    expect(json).to include("state" => "no_transcoder", "paused" => false)
    expect(json["message"]).to include("transcoder isn't running")
    expect(json["queue"]).to include("queued" => 1)
    expect(json["budget"]).to include("used_bytes" => 0, "budget_bytes" => 200.gigabytes, "full" => false)
  end

  describe "the Queue and Optimized tables" do
    def version_for(name, **attributes)
      library = create_library(household: household, roots: build_root)
      movie = Movie.create!(household: household, library: library, title: name, year: 2000)
      file = MediaFile.create!(household: household, library: library, path: "/m/#{name}.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 3600)
      file.media_streams.create!(index: 0, kind: "video", codec: "hevc", height: 1080)
      movie.editions.create!(media_file: file)
      OptimizedVersion.create!(household: household, media_file: file, **attributes)
    end

    def titles(params = {})
      get "/api/v1/optimized_versions", params: params, headers: auth_headers(admin)
      json["rows"].map { |row| row["title"] }
    end

    it "lists the queue in the transcoder's order, numbered over the whole queue whatever is searched" do
      version_for("Oldest")
      version_for("Asked", origin: "manual")
      version_for("Tonight", needed_at: 3.hours.from_now)
      version_for("Encoding", state: "encoding", progress: 0.5, started_at: 10.minutes.ago)
      version_for("Done", state: "ready", size: 5, started_at: 2.hours.ago, finished_at: 1.hour.ago)

      expect(titles).to eq([ "Encoding 2000", "Asked 2000", "Tonight 2000", "Oldest 2000", "Done 2000" ])
      get "/api/v1/optimized_versions", params: { q: "oldest" }, headers: auth_headers(admin)
      expect(json["rows"].sole).to include("queue_position" => 3, "estimated_bytes" => 6_160 * 1000 / 8 * 3600)
      expect(titles(states: %w[ready])).to eq([ "Done 2000" ])
      get "/api/v1/optimized_versions", params: { states: %w[ready] }, headers: auth_headers(admin)
      expect(json["rows"].sole).to include("encode_seconds" => 3600, "plays_since" => 0, "queue_position" => nil)
    end

    it "flags what won't fit in the budget, and what nobody has played in a while" do
      AppSetting.current.update!(optimize_budget_gb: 3)
      version_for("First")
      version_for("Second", reason: "airing")
      played = version_for("Played", state: "ready", size: 1, finished_at: 2.days.ago)
      PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: played.media_file.editions.sole.playable,
        media_file: played.media_file, method: "optimized", started_at: 1.day.ago, last_seen_at: 1.day.ago)
      version_for("Forgotten", state: "ready", size: 1, finished_at: 200.days.ago)

      get "/api/v1/optimized_versions", params: { states: %w[queued] }, headers: auth_headers(admin)
      # Each hour at 1080p is about 2.8 GB.
      expect(json["rows"].map { |row| row["fits_budget"] }).to eq([ true, false ])
      expect(titles(reasons: %w[airing])).to eq([ "Second 2000" ])
      expect(titles(states: %w[ready], unplayed_days: 90)).to eq([ "Forgotten 2000" ])
      get "/api/v1/optimized_versions", params: { states: %w[ready], sort: "plays", direction: "desc" }, headers: auth_headers(admin)
      expect(json["rows"].first).to include("title" => "Played 2000", "plays_since" => 1)
    end

    it "filters to the interrupted, and sorts by any column" do
      version_for("Calm", size: 9)
      version_for("Stopped", interruptions: 2, interruption: "quiet hours ended")
      expect(titles(interrupted: true)).to eq([ "Stopped 2000" ])
      expect(titles(sort: "interruptions", direction: "desc")).to eq([ "Stopped 2000", "Calm 2000" ])
      expect(titles(sort: "title", direction: "asc")).to eq([ "Calm 2000", "Stopped 2000" ])
    end
  end

  describe "bulk actions" do
    let!(:heat) { movie_with("hevc_main10_hdr10.mkv").media_files.sole }
    let!(:other) { movie_with("h264_hi10p.mkv").media_files.sole }

    def act(action, ids, **extra)
      post "/api/v1/optimized_versions/bulk", params: { bulk_action: action, media_file_ids: ids, **extra }, headers: auth_headers(admin)
      json
    end

    it "optimizes many at once, now if asked, and says why the rest didn't" do
      ready_version(other)
      expect(act("optimize", [ heat.id, other.id, SecureRandom.uuid ], now: true))
        .to eq("changed" => 1, "unchanged" => { "already made" => 1, "not found" => 1 })
      expect(heat.reload.optimized_version).to have_attributes(state: "queued", origin: "manual", run_now: true, reason: "manual")
      expect(act("optimize", [ heat.id ])).to eq("changed" => 0, "unchanged" => { "already queued" => 1 })
      expect(ActivityEntry.where(event: "optimize.optimize").sole.summary).to end_with("asked for an optimized version of 1 file, now")
    end

    it "puts one next in line" do
      OptimizedVersion.create!(household: household, media_file: other, origin: "manual")
      version = OptimizedVersion.create!(household: household, media_file: heat)
      expect(act("prioritize", [ heat.id ])).to include("changed" => 1)
      expect(OptimizedVersion.queued.in_queue_order.first).to eq(version)
    end

    it "stops making one for good, deleting it if made, until allowed again" do
      made = ready_version(other)
      expect(act("skip", [ heat.id, other.id ])).to include("changed" => 2)
      expect(made.path).not_to exist
      expect(OptimizedVersion.pluck(:state)).to all(eq("skipped"))

      expect(act("unskip", [ heat.id ])).to include("changed" => 1)
      expect(heat.reload.optimized_version).to be_nil
    end

    it "makes a ready one again, retries a failed one, and deletes" do
      made = ready_version(heat)
      failed = OptimizedVersion.create!(household: household, media_file: other, state: "failed", attempts: 3)
      expect(act("reencode", [ heat.id ])).to include("changed" => 1)
      expect(made.reload).to have_attributes(state: "queued", size: nil)
      expect(made.path).not_to exist
      expect(act("retry", [ other.id ], now: true)).to include("changed" => 1)
      expect(failed.reload).to have_attributes(state: "queued", run_now: true, attempts: 0)
      expect(act("delete", [ heat.id, other.id ])).to include("changed" => 2)
      expect(OptimizedVersion.count).to eq(0)
    end

    it "refuses an action it doesn't know" do
      act("explode", [ heat.id ])
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "looks for files to optimize when asked, unless that's turned off" do
    post "/api/v1/optimized_versions/scan", headers: auth_headers(admin)
    expect(response).to have_http_status(:accepted)
    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("QueueOptimizationsJob")

    AppSetting.current.update!(optimize_automatically: false)
    AppSetting.bust_cache!
    post "/api/v1/optimized_versions/scan", headers: auth_headers(admin)
    expect(json["errors"].sole).to include("off")
  end

  describe "the nightly pass" do
    let!(:file) { movie_with("hevc_main10_hdr10.mkv").media_files.sole }

    before do
      Device.create!(household: household, client_key: "chrome", name: "Chrome", capabilities: chrome, last_seen_at: Time.current)
    end

    it "queues files no recent device plays without converting, once" do
      h264 = movie_with("h264_aac.mp4").media_files.sole
      2.times { QueueOptimizationsJob.perform_now }
      expect(OptimizedVersion.sole).to have_attributes(media_file_id: file.id, origin: "automatic", state: "queued", reason: "all_devices")
      expect(OptimizedVersion.where(media_file: h264)).to be_empty
    end

    it "never queues a file an admin said not to optimize, and leaves an admin's own request as it is" do
      QueueOptimizationsJob.perform_now
      OptimizedVersion.sole.skip!
      QueueOptimizationsJob.perform_now
      expect(OptimizedVersion.sole.state).to eq("skipped")

      OptimizedVersion.sole.requeue!(origin: OptimizedVersion::Origin::Manual)
      OptimizedVersion.sole.prioritize!
      QueueOptimizationsJob.perform_now
      expect(OptimizedVersion.sole).to have_attributes(state: "queued", origin: "manual", reason: "manual")
      expect(OptimizedVersion.sole.prioritized_at).to be_present
    end

    it "queues a Grid program some recent device would convert, before it airs" do
      Device.create!(household: household, client_key: "safari", name: "Safari", last_seen_at: Time.current,
        capabilities: chrome.merge("video" => %w[h264 hevc hevc_10], "hdr" => %w[hdr10]))
      station = Station.create!(household: household, number: "4", name: "Four")
      Airing.create!(household: household, station: station, playable: file.editions.sole.playable, media_file: file, series_key: "movies",
        starts_at: 1.day.from_now, ends_at: 1.day.from_now + 2.hours, reason: "Test")
      QueueOptimizationsJob.perform_now
      expect(OptimizedVersion.sole).to have_attributes(media_file_id: file.id, origin: "automatic", reason: "airing")
      expect(OptimizedVersion.sole.needed_at).to be_within(1.second).of(1.day.from_now)
    end

    it "queues the next episode of a show someone is watching, if some device would convert it, needed now" do
      Device.create!(household: household, client_key: "safari", name: "Safari", last_seen_at: Time.current,
        capabilities: chrome.merge("video" => %w[h264 hevc hevc_10], "hdr" => %w[hdr10]))
      library = file.library
      show = Show.create!(household: household, library: library, folder: "Severance", title: "Severance")
      season = show.seasons.find_or_create_by!(season_number: 1)
      first = show.episodes.create!(season: season, season_number: 1, episode_number: 1, title: "Good News")
      first.editions.create!(media_file: movie_with("h264_aac.mp4").media_files.sole)
      nxt = show.episodes.create!(season: season, season_number: 1, episode_number: 2, title: "Half Loop")
      nxt.editions.create!(media_file: file)
      WatchState.create!(profile: Profile.default_for(household), playable: first, position_seconds: 60, duration_seconds: 60,
        completed_at: 1.day.ago, last_watched_at: 1.day.ago)

      QueueOptimizationsJob.perform_now
      expect(OptimizedVersion.sole).to have_attributes(media_file_id: file.id, reason: "next_up")
      expect(OptimizedVersion.sole.needed_at).to be_within(1.minute).of(Time.current)

      # Still needed now an hour on: the stamp stands, not a write a pass.
      travel 1.hour do
        expect { QueueOptimizationsJob.perform_now }.not_to(change { OptimizedVersion.sole.updated_at })
      end
    end

    it "leaves files alone that some recent device plays, and stops when turned off or out of room" do
      Device.create!(household: household, client_key: "safari", name: "Safari", last_seen_at: Time.current,
        capabilities: chrome.merge("video" => %w[h264 hevc hevc_10], "hdr" => %w[hdr10]))
      QueueOptimizationsJob.perform_now
      expect(OptimizedVersion.count).to eq(0)

      Device.find_by(client_key: "safari").destroy!
      AppSetting.current.update!(optimize_automatically: false)
      QueueOptimizationsJob.perform_now
      expect(OptimizedVersion.count).to eq(0)

      AppSetting.current.update!(optimize_automatically: true, optimize_budget_gb: 1)
      other = movie_with("h264_hi10p.mkv").media_files.sole
      ready_version(other).update!(size: 2.gigabytes)
      QueueOptimizationsJob.perform_now
      expect(OptimizedVersion.where(media_file: file)).to be_empty
    end
  end

  it "saves quiet hours, height and budget, refusing nonsense" do
    patch "/api/v1/app_setting", params: { optimize_quiet_start_hour: 23, optimize_quiet_end_hour: 6, optimize_max_height: 720,
      optimize_budget_gb: 50, optimize_automatically: false, optimize_paused: true }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(json).to include("optimize_paused" => true, "optimize_quiet_start_hour" => 23, "optimize_quiet_end_hour" => 6, "optimize_max_height" => 720,
      "optimize_budget_gb" => 50, "optimize_automatically" => false)
    setting = AppSetting.current
    expect(setting.quiet_hours?(Time.zone.parse("2026-09-26 23:30"))).to be(true)
    expect(setting.quiet_hours?(Time.zone.parse("2026-09-26 05:59"))).to be(true)
    expect(setting.quiet_hours?(Time.zone.parse("2026-09-26 06:00"))).to be(false)

    patch "/api/v1/app_setting", params: { optimize_quiet_start_hour: 24 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    patch "/api/v1/app_setting", params: { optimize_max_height: 1440 }, headers: auth_headers(admin)
    expect(json["errors"].sole).to include("720p, 1080p or 2160p")
  end
end
