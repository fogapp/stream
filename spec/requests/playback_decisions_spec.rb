# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Playback decisions", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:profile) { Profile.default_for(household) }
  let(:movie) { Movie.create!(household: household, library: library, title: "Heat", year: 1995) }

  def probed(name, container, streams)
    file = MediaFile.create!(household: household, library: library, path: "/m/#{name}", size: 1, mtime: Time.current,
      state: "probed", container: container)
    streams.each_with_index { |attrs, index| file.media_streams.create!({ index: index }.merge(attrs)) }
    movie.editions.create!(media_file: file)
    file
  end

  def session(method, summary, started_at: 1.hour.ago, device: nil)
    PlaybackSession.create!(household: household, profile: profile, playable: movie, media_file: probed("x#{SecureRandom.hex(2)}.mkv", "matroska,webm", []),
      method: method, decision: { "method" => method, "summary" => summary }, device: device, device_name: "Safari on macOS",
      started_at: started_at, last_seen_at: started_at)
  end

  let(:chrome) do
    Device.create!(household: household, client_key: "c", name: "Chrome on macOS", last_seen_at: Time.current,
      capabilities: { "hls" => "mse", "video" => %w[h264 vp9], "audio" => %w[aac opus], "containers" => %w[mp4 webm] })
  end
  let(:safari) do
    Device.create!(household: household, client_key: "s", name: "Safari on macOS", last_seen_at: Time.current,
      capabilities: { "hls" => "native", "video" => %w[h264 hevc hevc_10], "audio" => %w[aac ac3 eac3], "containers" => %w[mp4], "max_height" => 2160 })
  end

  it "summarizes the week: the split, the top reasons, stalls and errors" do
    # The default cap depends on the CPU (AVX2 allows two); pin it at one.
    allow(Playback::Encoders).to receive(:avx2?).and_return(false)
    session("direct", "Plays as-is")
    remux = session("remux", "Safari on macOS can't open MKV files — repackaged, no quality loss")
    session("remux", "Safari on macOS can't open MKV files — repackaged, no quality loss")
    session("video_transcode", "MPEG-2 video isn't supported here — converted to H.264 576p")
    session("direct", "Plays as-is", started_at: 9.days.ago)
    PlaybackEvent.create!(playback_session: remux, kind: "stall", created_at: Time.current)
    2.times { PlaybackEvent.create!(playback_session: remux, kind: "recovery", detail: { "message" => "bufferSeekOverHole" }, created_at: Time.current) }

    get "/api/v1/playback_decisions/summary", headers: auth_headers(admin)

    expect(json["methods"]).to eq("direct" => 1, "remux" => 2, "audio_transcode" => 0, "optimized" => 0, "video_transcode" => 1)
    expect(json["top_reasons"].first).to eq("summary" => "Safari on macOS can't open MKV files — repackaged, no quality loss", "count" => 2)
    expect(json).to include("stalls" => 1, "recoveries" => 2, "errors" => 0, "cap" => 1, "encoder" => "software")
  end

  it "times starting per method and seeking past what was buffered, typical and at worst" do
    remux = session("remux", "can't open MKV")
    direct = session("direct", "Plays as-is")
    [ 400, 600, 900, 2000 ].each { |ms| PlaybackEvent.create!(playback_session: remux, kind: "startup", detail: { "ms" => ms }, created_at: Time.current) }
    PlaybackEvent.create!(playback_session: direct, kind: "startup", detail: { "ms" => 300 }, created_at: Time.current)
    PlaybackEvent.create!(playback_session: direct, kind: "startup", detail: { "ms" => 5 }, created_at: 9.days.ago)
    PlaybackEvent.create!(playback_session: remux, kind: "seek", detail: { "ms" => 350, "ready" => false }, created_at: Time.current)
    PlaybackEvent.create!(playback_session: remux, kind: "seek", detail: { "ms" => 20, "ready" => true }, created_at: Time.current)

    get "/api/v1/playback_decisions/summary", headers: auth_headers(admin)

    expect(json.dig("startup", "remux")).to eq("count" => 4, "median_ms" => 600, "p95_ms" => 2000)
    expect(json.dig("startup", "direct")).to eq("count" => 1, "median_ms" => 300, "p95_ms" => 300)
    expect(json.dig("startup", "video_transcode")).to eq("count" => 0, "median_ms" => nil, "p95_ms" => nil)
    expect(json["seeks"]).to eq("count" => 1, "median_ms" => 350, "p95_ms" => 350)
  end

  it "lists sessions newest first with their verdict, reason and a fix hint, filterable by method" do
    session("remux", "can't open MKV", started_at: 2.hours.ago)
    session("video_transcode", "HDR on a screen that can't show it", started_at: 1.hour.ago)
      .update!(decision: { "method" => "video_transcode", "summary" => "HDR on a screen that can't show it", "video" => { "tonemap" => true } })

    get "/api/v1/playback_decisions", headers: auth_headers(admin)
    expect(json["rows"].map { |row| row["method"] }).to eq(%w[video_transcode remux])
    expect(json).to include("total" => 2, "page" => 1, "per" => 50, "total_capped" => false)
    expect(json["rows"].first).to include("title" => "Heat 1995", "fix_hint" => include("HDR"), "device" => include("name" => "Safari on macOS"),
      "outcome" => "clean", "stalls" => 0, "startup_ms" => nil)

    get "/api/v1/playback_decisions", params: { methods: [ "remux" ] }, headers: auth_headers(admin)
    expect(json["rows"].map { |row| row["method"] }).to eq(%w[remux])
  end

  describe "the Sessions table" do
    let!(:clean) { session("direct", "Plays as-is", started_at: 3.hours.ago) }
    let!(:stalled) { session("remux", "can't open MKV", started_at: 2.hours.ago) }
    let!(:errored) { session("remux", "can't open MKV", started_at: 90.minutes.ago) }
    let!(:failed) { session("video_transcode", "HEVC", started_at: 1.hour.ago) }

    before do
      failed.update!(transcode_error: "ffmpeg exited 1")
      2.times { PlaybackEvent.create!(playback_session: stalled, kind: "stall") }
      PlaybackEvent.create!(playback_session: errored, kind: "stall")
      PlaybackEvent.create!(playback_session: errored, kind: "error", detail: { "message" => "MEDIA_ERR_DECODE" })
      PlaybackEvent.create!(playback_session: errored, kind: "recovery",
        detail: { "message" => "mediaSourceRequiresReset", "cause" => "MediaError 3: PIPELINE_ERROR_DECODE", "count" => 1 })
      PlaybackEvent.create!(playback_session: clean, kind: "startup", detail: { "ms" => 300 })
      PlaybackEvent.create!(playback_session: stalled, kind: "startup", detail: { "ms" => 2400 })
      PlaybackEvent.create!(playback_session: errored, kind: "startup", detail: { "ms" => "garbage" })
    end

    def ids(params = {})
      get "/api/v1/playback_decisions", params: params, headers: auth_headers(admin)
      json["rows"].map { |row| row["id"] }
    end

    it "says how each one went, worst first" do
      get "/api/v1/playback_decisions", headers: auth_headers(admin)
      outcomes = json["rows"].to_h { |row| [ row["id"], row.values_at("outcome", "stalls", "errors", "startup_ms") ] }
      expect(outcomes).to eq(failed.id => [ "failed", 0, 0, nil ], errored.id => [ "errored", 1, 1, nil ],
        stalled.id => [ "stalled", 2, 0, 2400 ], clean.id => [ "clean", 0, 0, 300 ])
      expect(ids(sort: "outcome", direction: "asc")).to eq([ failed.id, errored.id, stalled.id, clean.id ])
    end

    it "filters to the plays that went wrong" do
      expect(ids(outcomes: %w[failed errored])).to eq([ failed.id, errored.id ])
      expect(ids(outcomes: %w[clean nonsense])).to eq([ clean.id ])
    end

    it "sorts by startup and stalls with the untimed last, either way" do
      expect(ids(sort: "startup_ms", direction: "desc")).to eq([ stalled.id, clean.id, failed.id, errored.id ])
      expect(ids(sort: "startup_ms", direction: "asc")).to eq([ clean.id, stalled.id, failed.id, errored.id ])
      expect(ids(sort: "stalls", direction: "desc").first).to eq(stalled.id)
      expect(ids(sort: "nonsense")).to eq([ failed.id, errored.id, stalled.id, clean.id ])
    end

    it "searches titles and filenames, and narrows by when" do
      other = Movie.create!(household: household, library: library, title: "Alien", year: 1979)
      clean.update!(playable: other)
      expect(ids(q: "alien")).to eq([ clean.id ])
      expect(ids(q: clean.media_file.filename)).to eq([ clean.id ])
      expect(ids(from: 100.minutes.ago.iso8601)).to eq([ failed.id, errored.id ])
      expect(ids(to: 100.minutes.ago.iso8601)).to eq([ stalled.id, clean.id ])
    end

    it "pages, with the total in the body" do
      get "/api/v1/playback_decisions", params: { per: 3, page: 2 }, headers: auth_headers(admin)
      expect(json).to include("total" => 4, "page" => 2, "per" => 3)
      expect(json["rows"].map { |row| row["id"] }).to eq([ clean.id ])
    end

    it "shows one in full: the decision and what the player said" do
      get "/api/v1/playback_decisions/#{errored.id}", headers: auth_headers(admin)
      expect(json).to include("id" => errored.id, "outcome" => "errored", "errors" => 1)
      expect(json["events"].map { |event| [ event["kind"], event["message"] ] })
        .to eq([ [ "stall", nil ], [ "error", "MEDIA_ERR_DECODE" ],
          [ "recovery", "mediaSourceRequiresReset: MediaError 3: PIPELINE_ERROR_DECODE" ], [ "startup", nil ] ])
    end

    it "lists who and what has played, for the filters" do
      clean.update!(device: chrome)
      get "/api/v1/playback_decisions/facets", headers: auth_headers(admin)
      expect(json["profiles"].map { |row| row["id"] }).to eq([ profile.id ])
      expect(json["devices"]).to eq([ { "id" => chrome.id, "name" => "Chrome on macOS" } ])
    end
  end

  # Every probed file's decision for every recent device is seconds of work
  # on a real library: the Playback page and the hourly optimize pass share
  # one answer, worked out again only once something it depends on changed.
  it "decides which files need converting once, until a file's probe, a device or a ready version changes" do
    chrome
    hevc = [ { kind: "video", codec: "hevc", bit_depth: 10, height: 2160 }, { kind: "audio", codec: "aac", channels: 2 } ]
    file = probed("a.mkv", "matroska,webm", hevc)
    report = -> { get "/api/v1/playback_decisions/transcode_report", headers: auth_headers(admin) }
    decided = -> { count_queries(matching: /FROM "media_streams"/, &report).size }

    expect(decided.call).to eq(1)
    expect(decided.call).to eq(0)
    expect(Playback::Report.needing_conversion(household).pluck(:filename)).to eq([ "a.mkv" ])

    probed("b.mkv", "matroska,webm", hevc)
    expect(decided.call).to eq(1)
    expect(json["rows"].pluck("filename")).to contain_exactly("a.mkv", "b.mkv")

    safari
    expect(decided.call).to eq(1)
    OptimizedVersion.create!(household_id: household.id, media_file: file, state: "ready", height: 1080)
    expect(decided.call).to eq(1)
    expect(decided.call).to eq(0)

    # Analysis writing to a file isn't a reason to decide again; a new probe is.
    file.update!(loudness_lufs: -23.0, true_peak_dbfs: -1.0, sidecar_subtitles: [])
    expect(decided.call).to eq(0)
    file.update!(probed_at: Time.current)
    expect(decided.call).to eq(1)
  end

  it "says which input sent it back to work" do
    chrome
    probed("a.mkv", "matroska,webm", [ { kind: "video", codec: "hevc", bit_depth: 10, height: 2160 } ])
    allow(Rails.logger).to receive(:info).and_call_original

    Playback::Report.needing_conversion(household)
    safari
    Playback::Report.needing_conversion(household)

    expect(Rails.logger).to have_received(:info).with(/worked out afresh for household #{household.id}: nothing_cached changed/)
    expect(Rails.logger).to have_received(:info).with(/worked out afresh for household #{household.id}: devices changed\z/)
  end

  it "reports which files a recent device would have to convert, and why" do
    chrome
    safari
    probed("a.mkv", "matroska,webm", [ { kind: "video", codec: "hevc", bit_depth: 10, height: 2160 }, { kind: "audio", codec: "aac", channels: 2 } ])
    probed("b.mp4", "mov,mp4,m4a,3gp,3g2,mj2", [ { kind: "video", codec: "h264", bit_depth: 8, height: 1080 }, { kind: "audio", codec: "aac", channels: 2 } ])

    get "/api/v1/playback_decisions/transcode_report", headers: auth_headers(admin)

    expect(json["rows"].map { |row| row["filename"] }).to eq([ "a.mkv" ])
    expect(json["rows"].first["devices"]).to eq([ { "device" => "Chrome on macOS", "summary" => "10-bit HEVC video isn't supported here — converted to H.264 1080p" } ])
    expect(json["rows"].first).to include("library" => { "id" => library.id, "name" => library.name }, "conversions" => 0,
      "last_converted_at" => nil, "status" => "none")
    expect(json["facets"]).to eq("devices" => [ "Chrome on macOS" ], "libraries" => [ { "id" => library.id, "name" => library.name } ])
  end

  describe "the Needs converting table" do
    let(:hevc) { [ { kind: "video", codec: "hevc", bit_depth: 10, height: 2160 }, { kind: "audio", codec: "aac", channels: 2 } ] }
    let(:mpeg2) { [ { kind: "video", codec: "mpeg2video", bit_depth: 8, height: 576 }, { kind: "audio", codec: "aac", channels: 2 } ] }
    let!(:everywhere) { probed("mpeg2.ts", "mpegts", mpeg2) }
    let!(:on_chrome) { probed("hevc.mkv", "matroska,webm", hevc) }

    before do
      chrome
      safari
      2.times do
        PlaybackSession.create!(household: household, profile: profile, playable: movie, media_file: on_chrome, method: "video_transcode",
          decision: {}, started_at: 1.day.ago, last_seen_at: 1.day.ago)
      end
      PlaybackSession.create!(household: household, profile: profile, playable: movie, media_file: on_chrome, method: "video_transcode",
        decision: {}, started_at: 40.days.ago, last_seen_at: 40.days.ago)
      OptimizedVersion.create!(household: household, media_file: everywhere, state: "failed")
    end

    def files(params = {})
      get "/api/v1/playback_decisions/transcode_report", params: params, headers: auth_headers(admin)
      json["rows"].map { |row| row["filename"] }
    end

    it "puts what converted most this month first, and counts only this month" do
      expect(files).to eq(%w[hevc.mkv mpeg2.ts])
      expect(json["rows"].first).to include("conversions" => 2, "status" => "none")
      expect(files(sort: "conversions", direction: "asc")).to eq(%w[mpeg2.ts hevc.mkv])
      expect(files(sort: "devices", direction: "desc")).to eq(%w[mpeg2.ts hevc.mkv])
    end

    it "filters by optimize status, device, every device and search" do
      expect(files(statuses: %w[none])).to eq(%w[hevc.mkv])
      expect(files(statuses: %w[failed nonsense])).to eq(%w[mpeg2.ts])
      expect(files(device: "Safari on macOS")).to eq(%w[mpeg2.ts])
      expect(files(all_devices: true)).to eq(%w[mpeg2.ts])
      expect(files(q: "HEVC")).to eq(%w[hevc.mkv])
      expect(files(library_id: SecureRandom.uuid)).to eq([])
    end

    it "pages" do
      get "/api/v1/playback_decisions/transcode_report", params: { per: 1, page: 2 }, headers: auth_headers(admin)
      expect(json).to include("total" => 2, "page" => 2)
      expect(json["rows"].map { |row| row["filename"] }).to eq(%w[mpeg2.ts])
    end
  end

  it "shows a file's analysis page with what each device would get" do
    chrome
    safari
    file = probed("a.mkv", "matroska,webm", [ { kind: "video", codec: "hevc", bit_depth: 10, height: 1080 }, { kind: "audio", codec: "aac", channels: 2 } ])

    get "/api/v1/media_files/#{file.id}", headers: auth_headers(admin)

    expect(json["titles"]).to eq([ { "kind" => "movie", "id" => movie.id, "title" => "Heat 1995", "path" => "/movie/#{movie.id}" } ])
    expect(json["devices"].map { |row| [ row.dig("device", "name"), row["method"] ] })
      .to contain_exactly([ "Chrome on macOS", "video_transcode" ], [ "Safari on macOS", "remux" ])
  end

  it "reruns a step from the checklist" do
    file = probed("a.mkv", "matroska,webm", [])
    post "/api/v1/media_files/#{file.id}/rerun", params: { step: "keyframes" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:accepted)
    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("IndexKeyframesJob")

    post "/api/v1/media_files/#{file.id}/rerun", params: { step: "nonsense" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "keeps the transcode limit between 1 and 8, or automatic" do
    patch "/api/v1/app_setting", params: { max_video_transcodes: 2 }, headers: auth_headers(admin)
    expect(json).to include("max_video_transcodes" => 2, "encoder" => "software")
    patch "/api/v1/app_setting", params: { max_video_transcodes: 12 }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    patch "/api/v1/app_setting", params: { max_video_transcodes: "" }, headers: auth_headers(admin)
    expect(json["max_video_transcodes"]).to be_nil
  end

  it "says whether playback is healthy, check by check" do
    session("video_transcode", "HEVC").update!(transcode_error: "ffmpeg exited 1")
    get "/api/v1/playback_decisions/health", headers: auth_headers(admin)
    expect(json["status"]).to eq("act")
    expect(json["checks"].map { |check| check["key"] }).to eq(%w[failed_plays live_conversions startup optimizer])
    expect(json["checks"].first).to include("status" => "act", "title" => "Plays that ended on an error", "metric" => "100.0%",
      "link" => include("tab" => "sessions", "outcomes" => %w[failed errored]))
  end

  it "is for admins only" do
    get "/api/v1/playback_decisions", headers: auth_headers(create_user(household: household))
    expect(response).to have_http_status(:forbidden)
  end
end
