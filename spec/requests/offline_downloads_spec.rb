# typed: false
# frozen_string_literal: true

require "rails_helper"

# Offline downloads from the outside (PROPOSAL §11 Phase 6): only what this
# browser plays as-is can be saved; the link is signed, expires and dies with
# the row; watching offline counts once the device is back.
RSpec.describe "Offline downloads", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
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

  def download(movie)
    post "/api/v1/offline_downloads", params: { playable_type: "movie", playable_id: movie.id, capabilities: chrome },
      headers: auth_headers(user)
  end

  it "saves a file this browser plays as-is, behind a signed link with its subtitles" do
    movie = movie_with("h264_aac_movtext.mp4")
    download(movie)
    expect(response).to have_http_status(:created)
    expect(json).to include("title" => "Heat", "mime_type" => "video/mp4", "optimized" => false, "resume_at" => 0.0,
      "playable" => { "type" => "movie", "id" => movie.id })
    expect(json["file_url"]).to match(%r{\A/media/d/[^/]+/file\.mp4\z})
    expect(json["subtitles"].sole["url"]).to match(%r{/subtitles/[a-z0-9]+\.vtt\z})

    file_url = json["file_url"]
    subtitle_url = json.dig("subtitles", 0, "url")
    get file_url, headers: { "Range" => "bytes=0-99" }
    expect(response).to have_http_status(:partial_content)
    expect_sent_by_thruster(file_url, movie.media_files.sole.path)
    get subtitle_url
    expect(response.body).to start_with("WEBVTT")
    expect(response.media_type).to eq("text/vtt")

    delete "/api/v1/offline_downloads/#{OfflineDownload.sole.id}", headers: auth_headers(user)
    get file_url
    expect(response).to have_http_status(:not_found)
  end

  it "refuses what would need converting, until there's an optimized version" do
    movie = movie_with("hevc_main10_hdr10.mkv")
    download(movie)
    expect(response).to have_http_status(:conflict)
    expect(json["errors"].sole).to include("would need it converted", "optimized version")

    file = movie.media_files.sole
    version = OptimizedVersion.create!(household: household, media_file: file, state: "ready", height: 1080,
      audio_stream_index: file.media_streams.find { |stream| stream.kind == "audio" }&.index)
    FileUtils.mkdir_p(OptimizedVersion.root)
    File.binwrite(version.path, "optimized")
    version.update!(size: 9)

    download(movie)
    expect(json).to include("optimized" => true, "size" => 9)
    get json["file_url"]
    expect(response.body).to eq("optimized")
  end

  it "stops working once it expires" do
    download(movie_with("h264_aac.mp4"))
    url = json["file_url"]
    OfflineDownload.sole.update!(expires_at: 1.minute.ago)
    get url
    expect(response).to have_http_status(:not_found)
  end

  it "refuses a forged link, and a playback session's token in a download's place" do
    download(movie_with("h264_aac.mp4"))
    url = json["file_url"]
    id = OfflineDownload.sole.id

    get url.sub(%r{/d/[^/]+/}, "/d/#{id}.#{'0' * 32}/")
    expect(response).to have_http_status(:not_found)
    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: OfflineDownload.sole.playable_id },
      headers: auth_headers(user)
    stream_token = json.dig("source", "url")[%r{/media/s/([^/]+)/}, 1]
    get url.sub(%r{/d/[^/]+/}, "/d/#{stream_token}/")
    expect(response).to have_http_status(:not_found)
  end

  it "is one profile's: another can't see, count or delete it" do
    download(movie_with("h264_aac.mp4"))
    id = json["id"]
    other = auth_headers(create_user(household: household)).merge(profile_header(Profile.create!(household: household, name: "Sam")))

    delete "/api/v1/offline_downloads/#{id}", headers: other
    expect(response).to have_http_status(:not_found)
    expect(OfflineDownload.exists?(id)).to be(true)

    delete "/api/v1/offline_downloads/#{id}", headers: auth_headers(user)
    expect(response).to have_http_status(:no_content)
    expect(OfflineDownload.exists?(id)).to be(false)
  end

  it "counts what was watched offline, as of when, once back online" do
    movie = movie_with("h264_aac.mp4")
    download(movie)
    id = json["id"]
    duration = movie.media_files.sole.duration_seconds

    post "/api/v1/offline_downloads/#{id}/progress", params: { position: duration, watched_at: 2.hours.ago.iso8601 },
      headers: auth_headers(user)
    expect(json).to include("completed" => true)
    state = WatchState.find_by(playable: movie)
    expect(state.play_count).to eq(1)
    expect(state.last_watched_at).to be_within(1.minute).of(2.hours.ago)

    other = create_user(household: household)
    post "/api/v1/offline_downloads/#{id}/progress", params: { position: 1 },
      headers: auth_headers(other).merge(profile_header(Profile.create!(household: household, name: "Kid")))
    expect(response).to have_http_status(:not_found)
  end

  it "carries an episode's skippable parts and what comes after it, for the offline player" do
    tv = create_library(household: household, roots: build_root, kind: "shows", name: "TV")
    show = Show.create!(household: household, library: tv, folder: "Severance", title: "Severance")
    season = show.seasons.create!(season_number: 1)
    episodes = [ 1, 2 ].map do |number|
      path = File.join(build_root("e#{number}.mp4" => "h264_aac.mp4"), "e#{number}.mp4")
      file = MediaFile.create!(household: household, library: tv, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
      Media::FileProber.new(file).call
      show.episodes.create!(season: season, season_number: 1, episode_number: number).tap { |episode| episode.editions.create!(media_file: file) }
    end
    Marker.offer(episodes.first.media_files.sole, Marker::Kind::Intro, start: 1.0, finish: 2.0, source: Marker::Source::Manual)
    Profile.default_for(household).update!(always_skip_intro: true)

    post "/api/v1/offline_downloads", params: { playable_type: "episode", playable_id: episodes.first.id, capabilities: chrome },
      headers: auth_headers(user)
    expect(json["markers"]).to eq([ { "kind" => "intro", "start" => 1.0, "end" => 2.0 } ])
    expect(json["skip"]).to include("intro" => true)
    expect(json["next_episode_id"]).to eq(episodes.second.id)
  end
end
