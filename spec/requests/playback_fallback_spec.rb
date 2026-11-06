# typed: false
# frozen_string_literal: true

require "rails_helper"

# A play that fails carries on a rung down the ladder, from where it got to,
# and one that fell back for a passing reason climbs back.
RSpec.describe "Playback fallback", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }

  def chrome_caps
    { "hls" => "mse", "containers" => %w[mp4 webm], "video" => %w[h264 vp9 av1], "audio" => %w[aac opus ac3],
      "max_audio_channels" => 6, "hdr" => [], "max_height" => 1080 }
  end

  def movie_with(fixture)
    name = "Heat (1995)/Heat.#{File.extname(fixture).delete('.')}"
    root = build_root(name => fixture)
    library = create_library(household: household, roots: root)
    file = MediaFile.create!(household: household, library: library, path: File.join(root, name), size: File.size(media_fixture(fixture)),
      mtime: Time.current, state: "probed")
    Media::FileProber.new(file).call
    movie = Movie.create!(household: household, library: library, title: "Heat", year: 1995)
    movie.editions.create!(media_file: file)
    movie
  end

  def play(movie)
    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id, device_key: "laptop-1",
      capabilities: chrome_caps }, headers: auth_headers(user).merge("User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/140.0 Safari/537.36"),
      as: :json
    expect(response).to have_http_status(:created)
    json
  end

  def fall_back(session_id, failure_class, position: 12.0, cause: "MediaError 3: decode")
    post "/api/v1/playback_sessions/#{session_id}/fallback", params: { failure_class: failure_class, position: position, cause: cause },
      headers: auth_headers(user), as: :json
    json
  end

  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::Signal).to receive(:request)
    allow(Playback::Encoders).to receive(:kind).and_return(Playback::Encoders::Kind::Software)
  end

  after { FileUtils.rm_rf(@cache) }

  it "converts the picture when the browser couldn't decode the file it played as-is, from where it got to" do
    first = play(movie_with("h264_aac.mp4"))
    expect(first["method"]).to eq("direct")

    lower = fall_back(first["id"], "decode")
    expect(response).to have_http_status(:created)
    expect(lower).to include("method" => "video_transcode", "resume_at" => 12.0)
    expect(lower["fallback"]).to eq("from_method" => "direct", "failure_class" => "decode", "upgradable" => false)
    expect(lower.dig("decision", "summary")).to eq("Playing as-is didn't play (the browser couldn't decode it at 0:12) — fell back")

    failed = PlaybackSession.find(first["id"])
    expect(failed).to have_attributes(state: "ended", failure_class: "decode", failure_cause: "MediaError 3: decode", position_seconds: 12.0)
    carried = PlaybackSession.find(lower["id"])
    expect(carried).to have_attributes(fallback_from_id: failed.id, media_file_id: failed.media_file_id, device_id: failed.device_id,
      position_seconds: 12.0)
    expect(carried.decision["constraints"]).to eq("no_direct" => true, "convert_video" => true)
    expect(PlaybackEvent.where(playback_session: failed, kind: "error").sole.detail).to include("message" => "fell back (decode)")
    expect(PlaybackEvent.where(playback_session: carried, kind: "start")).to be_empty
  end

  it "steps down a rung at a time for a file it wouldn't open, and says what it tried when nothing's left" do
    first = play(movie_with("h264_aac_ac3_subs.mkv"))
    expect(first["method"]).to eq("remux")

    sound = fall_back(first["id"], "unsupported")
    expect(sound["method"]).to eq("audio_transcode")
    expect(PlaybackSession.find(sound["id"]).decision["audio"]).to include("copy" => false, "codec" => "aac", "channels" => 2)

    picture = fall_back(sound["id"], "unsupported", position: 30.0)
    expect(picture["method"]).to eq("video_transcode")

    # Software already, so a picture converted that still fails is the end.
    fall_back(picture["id"], "stalled", position: 31.0)
    expect(response).to have_http_status(:conflict)
    expect(json["errors"].sole).to eq("This couldn't be played on Chrome on macOS. Tried repackaging: the browser wouldn't open it at 0:12; " \
      "converting the sound: the browser wouldn't open it at 0:30; converting the picture: it stopped getting anywhere at 0:31.")
  end

  it "answers a second report of the same failure with the session it already carried on as" do
    first = play(movie_with("h264_aac.mp4"))
    lower = fall_back(first["id"], "decode")
    again = fall_back(first["id"], "decode")
    expect(response).to have_http_status(:ok)
    expect(again["id"]).to eq(lower["id"])
    expect(PlaybackSession.where(fallback_from_id: first["id"]).count).to eq(1)
    expect(again.except("resume_at")).to eq(lower.except("resume_at"))
  end

  it "answers with what the session was decided, whatever would be decided now" do
    first = play(movie_with("h264_aac.mp4"))
    lower = fall_back(first["id"], "decode")
    allow(Playback::Plan).to receive(:again).and_raise("decided again")

    expect(fall_back(first["id"], "decode").dig("decision", "summary")).to eq(lower.dig("decision", "summary"))
  end

  it "climbs back after a passing failure, and stays down if climbing back fails too" do
    first = play(movie_with("h264_aac_ac3_subs.mkv"))
    lower = fall_back(first["id"], "stalled")
    expect(lower["method"]).to eq("audio_transcode")
    expect(lower["fallback"]).to include("upgradable" => true)

    post "/api/v1/playback_sessions/#{lower['id']}/upgrade", params: { position: 140.0 }, headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:created)
    upgraded = json
    expect(upgraded).to include("method" => "remux", "resume_at" => 140.0, "fallback" => nil)
    expect(PlaybackSession.find(lower["id"])).to have_attributes(state: "ended", failure_class: nil)

    # The rung it climbed back to fails: back down to the one that worked, for good.
    down = fall_back(upgraded["id"], "decode", position: 150.0)
    expect(down["method"]).to eq("audio_transcode")
    expect(down["fallback"]).to include("upgradable" => false)
    post "/api/v1/playback_sessions/#{down['id']}/upgrade", headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:no_content)
  end

  it "has nothing to climb back to after a failure that was the client's own" do
    lower = fall_back(play(movie_with("h264_aac.mp4"))["id"], "decode")
    post "/api/v1/playback_sessions/#{lower['id']}/upgrade", headers: auth_headers(user), as: :json
    expect(response).to have_http_status(:no_content)
  end

  it "answers 424 for a segment the transcoder has given up on, so the player falls back at once" do
    first = play(movie_with("h264_aac_ac3_subs.mkv"))
    PlaybackSession.find(first["id"]).update_columns(transcode_error: "ffmpeg exited 1: Invalid data found") # rubocop:disable Rails/SkipsModelValidations
    base = first.dig("source", "url").sub(%r{/[^/]+\z}, "")
    get "#{base}/seg-0.m4s"
    expect(response).to have_http_status(:failed_dependency)
    expect(response.body).to eq("ffmpeg exited 1: Invalid data found")
  end

  describe "remembering" do
    it "skips the way that failed for this file on this browser next time, and an admin can forget it" do
      movie = movie_with("h264_aac.mp4")
      first = play(movie)
      fall_back(first["id"], "decode")

      again = play(movie)
      expect(again["method"]).to eq("video_transcode")
      expect(again.dig("decision", "summary")).to eq("Playing as-is failed for this file on Chrome 140 on macOS before — skipped")

      admin = create_user(household: household, role: "admin")
      get "/api/v1/playback_lessons", headers: auth_headers(admin)
      lesson = json["rows"].sole
      expect(lesson).to include("rung" => "direct", "client_class" => "Chrome 140 on macOS", "failure_class" => "decode", "active" => true)
      get "/api/v1/playback_lessons", headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)

      delete "/api/v1/playback_lessons/#{lesson['id']}", headers: auth_headers(admin)
      expect(response).to have_http_status(:no_content)
      expect(play(movie)["method"]).to eq("direct")
    end

    it "learns nothing from a stall, and counts a rung that played thirty seconds as working" do
      movie = movie_with("h264_aac.mp4")
      first = play(movie)
      fall_back(first["id"], "stalled")
      expect(Playability.where(last_failed_at: ..Time.current)).to be_empty

      session = play(movie)
      progress = session["progress_url"]
      post progress, params: { position: 10.0 }, as: :json
      expect(Playability.count).to eq(0)
      post progress, params: { position: 31.0 }, as: :json
      post progress, params: { position: 62.0 }, as: :json
      expect(Playability.sole).to have_attributes(rung: "direct", successes: 1, failures: 0, client_class: "Chrome 140 on macOS")
    end
  end
end
