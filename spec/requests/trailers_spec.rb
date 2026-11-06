# typed: false
# frozen_string_literal: true

require "rails_helper"

# Trailers (PROPOSAL §7.1–7.2): TMDB names one, yt-dlp fetches it into
# storage, and a signed URL plays it — on the title's page and behind
# Home's hero. yt-dlp is stubbed, as everywhere in specs.
RSpec.describe "Trailers", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:movie) do
    Movie.create!(household: household, library: library, title: "Heat", year: 1995, tmdb_id: 949).tap do |movie|
      movie.editions.create!(media_file: MediaFile.create!(household: household, library: library, path: "/m/heat.mkv", size: 1,
        mtime: Time.current, state: "probed"))
    end
  end

  let(:videos) do
    [
      { "site" => "YouTube", "key" => "aaaaaaaaaaa", "type" => "Teaser", "official" => true, "iso_639_1" => "en", "published_at" => "2020" },
      { "site" => "YouTube", "key" => "bbbbbbbbbbb", "type" => "Trailer", "official" => false, "iso_639_1" => "en", "published_at" => "2021" },
      { "site" => "YouTube", "key" => "0xbfvnXdGEI", "type" => "Trailer", "official" => true, "iso_639_1" => "en", "published_at" => "2019",
        "name" => "Official Trailer" },
      { "site" => "Vimeo", "key" => "123", "type" => "Trailer", "official" => true }
    ]
  end

  before do
    @storage = Dir.mktmpdir("stream-storage")
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => @storage))
  end

  after { FileUtils.rm_rf(@storage) }

  def fetch_succeeds
    allow(Youtube::YtDlp).to receive(:download) do |url, args|
      expect(url).to eq("https://www.youtube.com/watch?v=0xbfvnXdGEI")
      home = args[args.index("--paths") + 1].delete_prefix("home:")
      File.write(File.join(home, "trailer.mp4"), "trailer bytes")
      ToolRunner::Result.new(status: 0, stdout: "#{File.join(home, 'trailer.mp4')}\n", stderr: "")
    end
  end

  it "picks the official YouTube trailer over teasers and unofficial ones" do
    expect(Trailers.best(videos)["key"]).to eq("0xbfvnXdGEI")
    expect(Trailers.best(videos.first(1))["key"]).to eq("aaaaaaaaaaa")
    expect(Trailers.best([ videos.last ])).to be_nil
  end

  it "fetches it into storage when TMDB names it, and plays it from a signed URL on the page and the hero" do
    fetch_succeeds
    perform_enqueued_jobs { Trailers.remember(movie, videos) }
    trailer = Trailer.sole
    expect(trailer).to have_attributes(youtube_id: "0xbfvnXdGEI", name: "Official Trailer", state_enum: Trailer::State::Ready, size: 13)

    get "/api/v1/movies/#{movie.id}", headers: auth_headers(user)
    url = json.dig("trailer", "url")
    expect(url).to match(%r{\A/trailers/#{trailer.id}/\h+\.mp4\z})
    get "/api/v1/home", headers: auth_headers(user)
    expect(json.dig("hero", "trailer", "url")).to eq(url)

    get url
    expect(response.body).to eq("trailer bytes")
    expect_sent_by_thruster(url, trailer.path)
    # Well-formed hex, so these reach the signature check rather than
    # failing the route: a made-up signature, and one signed for another id.
    get "/trailers/#{trailer.id}/#{'0' * 24}.mp4"
    expect(response).to have_http_status(:not_found)
    get "/trailers/#{trailer.id}/#{Trailers.send(:signature, SecureRandom.uuid)}.mp4"
    expect(response).to have_http_status(:not_found)

    # The same trailer again changes nothing; a new one replaces it.
    expect { Trailers.remember(movie, videos) }.not_to have_enqueued_job(FetchTrailerJob)
    Trailers.remember(movie, [ videos.second ])
    expect(trailer.reload).to have_attributes(youtube_id: "bbbbbbbbbbb", state_enum: Trailer::State::Queued)
    expect(trailer.path).not_to exist
  end

  it "keeps a failure on the trailer, and the daily pass finds missing ones and tries failed ones again" do
    allow(Youtube::YtDlp).to receive(:download).and_raise(Youtube::YtDlp::Error, "Video unavailable")
    perform_enqueued_jobs { Trailers.remember(movie, videos) }
    trailer = Trailer.sole
    expect(trailer).to have_attributes(state_enum: Trailer::State::Failed, error: "Video unavailable", attempts: 1)
    get "/api/v1/movies/#{movie.id}", headers: auth_headers(user)
    expect(json["trailer"]).to be_nil

    TmdbSetting.create!(household: household, api_key: "k")
    other = Movie.create!(household: household, library: library, title: "Ronin", tmdb_id: 8195)
    stub_request(:get, %r{api.themoviedb.org/3/movie/8195/videos}).to_return(status: 200, body: { results: videos }.to_json,
      headers: { "Content-Type" => "application/json" })
    trailer.update_columns(updated_at: 1.day.ago)
    expect { FetchTrailersJob.perform_now }.to have_enqueued_job(FetchTrailerJob).with(trailer.id)
    perform_enqueued_jobs(only: CheckTrailerJob)
    expect(Trailer.find_by(owner: other).youtube_id).to eq("0xbfvnXdGEI")
  end

  # A title TMDB has no trailer for leaves no Trailer row: without a note
  # of having asked, the same few are asked about every day for ever, and
  # the titles behind them never.
  it "works down the catalogue, past titles TMDB has no trailer for" do
    stub_const("FetchTrailersJob::PER_RUN", 1)
    TmdbSetting.create!(household: household, api_key: "k")
    Movie.create!(household: household, library: library, title: "Ronin", tmdb_id: 8195)
    Movie.create!(household: household, library: library, title: "Thief", tmdb_id: 11_524)
    stub = stub_request(:get, %r{api.themoviedb.org/3/movie/\d+/videos}).to_return(status: 200, body: { results: [] }.to_json,
      headers: { "Content-Type" => "application/json" })

    2.times do
      FetchTrailersJob.perform_now
      perform_enqueued_jobs(only: CheckTrailerJob)
    end
    FetchTrailersJob.perform_now

    expect(stub).to have_been_requested.twice
    expect(enqueued_jobs.select { |job| job["job_class"] == "CheckTrailerJob" }).to be_empty
    expect(Movie.where(trailer_checked_at: nil)).to be_empty
  end

  it "leaves a title it couldn't ask about first in line, and says so once" do
    TmdbSetting.create!(household: household, api_key: "k")
    Movie.create!(household: household, library: library, title: "Ronin", tmdb_id: 8195)
    Movie.create!(household: household, library: library, title: "Thief", tmdb_id: 11_524)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    stub_request(:get, %r{api.themoviedb.org/3/movie/\d+/videos}).to_return(status: 401, body: "{}")

    FetchTrailersJob.perform_now
    perform_enqueued_jobs(only: CheckTrailerJob)

    expect(Movie.where.not(trailer_checked_at: nil)).to be_empty
    expect(ActivityEntry.where(event: "trailers.check_failed").count).to eq(1)
    expect(ActivityEntry.where(event: "job.dead")).to be_empty
  end

  it "fetches nothing when Settings say not to" do
    AppSetting.current.update!(fetch_trailers: false)
    AppSetting.bust_cache!
    expect { Trailers.remember(movie, videos) }.not_to have_enqueued_job(FetchTrailerJob)
    expect(Trailer.sole.state_enum).to eq(Trailer::State::Queued)
  end

  # Backups leave trailer videos out (FogBackup::Producer::EXCLUDED), so
  # after a restore a ready trailer may have no file: it goes back in line.
  it "requeues ready trailers whose file a restore didn't bring back" do
    other = Movie.create!(household: household, library: library, title: "Ronin", year: 1998)
    kept = Trailer.create!(household: household, owner: movie, youtube_id: "aaaaaaaaaaa", name: "Heat", state: "ready",
      attempts: 1, size: 1)
    lost = Trailer.create!(household: household, owner: other, youtube_id: "bbbbbbbbbbb", name: "Ronin", state: "ready",
      attempts: 1, size: 1)
    Trailer.root.mkpath
    kept.path.write("trailer bytes")

    expect { Trailers.requeue_missing! }.to have_enqueued_job(FetchTrailerJob).with(lost.id).exactly(:once)

    expect(kept.reload.state).to eq("ready")
    expect(lost.reload).to have_attributes(state: "queued", attempts: 0, size: nil)
  end
end
