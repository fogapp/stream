# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Bringing Trakt into Stream", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:profile) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:heat) { Movie.create!(household: household, library: library, title: "Heat", year: 1995, tmdb_id: 949) }
  let(:ronin) { Movie.create!(household: household, library: library, title: "Ronin", year: 1998, imdb_id: "tt0122690") }
  let(:show) { Show.create!(household: household, library: library, folder: "Office", title: "The Office", tvdb_id: 73_244) }
  let(:season) { show.seasons.create!(season_number: 2) }
  let(:halloween) { show.episodes.create!(season: season, season_number: 2, episode_number: 5, title: "Halloween") }
  let(:fight) { show.episodes.create!(season: season, season_number: 2, episode_number: 2, title: "The Fight") }
  let!(:account) do
    TraktSetting.create!(household: household, client_id: "client-abc", client_secret: "secret-xyz")
    TraktAccount.create!(household: household, profile: profile, state: "linked", access_token: "at-1", refresh_token: "rt-1",
      expires_at: 1.day.from_now)
  end
  let(:t0) { Time.zone.parse("2026-09-20T20:00:00Z") }

  before { allow_any_instance_of(Trakt::Api).to receive(:sleep) } # rubocop:disable RSpec/AnyInstance

  def trakt_get(path, body)
    stub_request(:get, "https://api.trakt.tv#{path}").to_return(status: 200, body: body.to_json)
  end

  def activities(overrides = {})
    base = { "movies" => { "watched_at" => "a", "paused_at" => "a", "rated_at" => "a", "watchlisted_at" => "a" },
             "episodes" => { "watched_at" => "a", "paused_at" => "a", "rated_at" => "a", "watchlisted_at" => "a" },
             "shows" => { "rated_at" => "a" } }
    base.deep_merge(overrides)
  end

  def movie_ids(movie) = { ids: { tmdb: movie.tmdb_id, imdb: movie.imdb_id }.compact }
  def show_ids = { ids: { tvdb: 73_244 } }

  it "merges both sides on the first sync" do
    trakt_get("/sync/last_activities", activities)
    trakt_get("/sync/watched/movies", [ { plays: 2, last_watched_at: t0.iso8601, movie: movie_ids(heat) } ])
    trakt_get("/sync/watched/shows", [ { show: show_ids, seasons: [ { number: 2, episodes: [ { number: 5, plays: 1, last_watched_at: t0.iso8601 } ] } ] } ])
    trakt_get("/sync/playback/movies", [ { progress: 40.0, paused_at: t0.iso8601, movie: movie_ids(ronin) } ])
    trakt_get("/sync/playback/episodes", [])
    trakt_get("/sync/ratings/movies", [ { rating: 8, rated_at: t0.iso8601, movie: movie_ids(heat) } ])
    trakt_get("/sync/ratings/shows", [])
    trakt_get("/sync/ratings/episodes", [])
    trakt_get("/sync/watchlist/movies", [ { movie: movie_ids(ronin) } ])
    trakt_get("/sync/watchlist/episodes", [])
    MediaFile.create!(household: household, library: library, path: "/m/ronin.mkv", size: 1, mtime: Time.current, state: "probed",
      duration_seconds: 1000.0).tap { |file| ronin.editions.create!(media_file: file) }
    # Stream's own, which Trakt doesn't have yet.
    WatchState.create!(profile: profile, playable: fight, completed_at: t0 - 1.day, last_watched_at: t0 - 1.day, play_count: 1)
    Rating.create!(profile: profile, rateable: show, value: 9, rated_at: t0)
    PlaylistItem.create!(playlist: Playlist.watch_later_for(profile), item: halloween, position: 1)

    Trakt::Pull.new(account).call

    expect(WatchState.find_by(playable: heat)).to have_attributes(completed_at: t0, play_count: 2)
    expect(WatchState.find_by(playable: halloween)).to have_attributes(completed_at: t0, play_count: 1)
    expect(WatchState.find_by(playable: ronin)).to have_attributes(position_seconds: 400.0, completed_at: nil)
    expect(Rating.find_by(rateable: heat).value).to eq(8.0)
    expect(Playlist.watch_later_for(profile).playlist_items.pluck(:item_id)).to contain_exactly(halloween.id, ronin.id)
    expect(TraktChange.order(:action).pluck(:action, :item_id))
      .to contain_exactly([ "history_add", fight.id ], [ "rating_set", show.id ], [ "watchlist_add", halloween.id ])
    expect(account.reload).to have_attributes(last_activities: activities, last_synced_at: be_present)
    expect(account.synced_keys).to eq("ratings" => [ "Movie:#{heat.id}" ], "watchlist" => [ "Movie:#{ronin.id}" ])
    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("TraktPushJob")
  end

  context "once synced" do
    before do
      account.update!(last_activities: activities, last_synced_at: t0,
        synced_keys: { "ratings" => [ "Movie:#{heat.id}" ], "watchlist" => [ "Movie:#{ronin.id}" ] })
    end

    it "asks only for what changed, and takes new plays from other apps" do
      halloween
      trakt_get("/sync/last_activities", activities("episodes" => { "watched_at" => "b" }))
      history = stub_request(:get, "https://api.trakt.tv/sync/history/episodes?limit=100&page=1&start_at=a")
        .to_return(status: 200, body: [ { watched_at: (t0 + 1.hour).iso8601, episode: { season: 2, number: 5 }, show: show_ids } ].to_json)

      Trakt::Pull.new(account).call

      expect(history).to have_been_requested
      expect(WatchState.find_by(playable: halloween)).to have_attributes(completed_at: t0 + 1.hour, play_count: 1)
      expect(TraktChange.count).to eq(0)
    end

    it "reads history a page at a time until a short page, and a replayed page changes nothing" do
      heat
      trakt_get("/sync/last_activities", activities("movies" => { "watched_at" => "b" }))
      full = Array.new(100) { |index| { watched_at: (t0 - index.days).iso8601, movie: { ids: { tmdb: 1_000_000 + index } } } }
      first = stub_request(:get, "https://api.trakt.tv/sync/history/movies?limit=100&page=1&start_at=a")
        .to_return(status: 200, body: full.to_json)
      second = stub_request(:get, "https://api.trakt.tv/sync/history/movies?limit=100&page=2&start_at=a")
        .to_return(status: 200, body: [ { watched_at: (t0 + 1.hour).iso8601, movie: movie_ids(heat) } ].to_json)
      third = stub_request(:get, "https://api.trakt.tv/sync/history/movies?limit=100&page=3&start_at=a")

      Trakt::Pull.new(account).call

      expect([ first, second ]).to all(have_been_requested.once)
      expect(third).not_to have_been_requested
      state = WatchState.find_by(playable: heat)
      expect(state).to have_attributes(completed_at: t0 + 1.hour, play_count: 1)

      # The same history again — a retried pull, or Trakt sending it twice.
      account.update!(last_activities: activities)
      expect { Trakt::Pull.new(account).call }.not_to(change { state.reload.attributes })
      expect(WatchState.count).to eq(1)
    end

    it "knows its own plays when they come back" do
      state = WatchState.create!(profile: profile, playable: heat, completed_at: t0, last_watched_at: t0, play_count: 1)
      trakt_get("/sync/last_activities", activities("movies" => { "watched_at" => "b" }))
      stub_request(:get, "https://api.trakt.tv/sync/history/movies?limit=100&page=1&start_at=a")
        .to_return(status: 200, body: [ { watched_at: (t0 + 3.minutes).iso8601, movie: movie_ids(heat) } ].to_json)

      Trakt::Pull.new(account).call

      expect(state.reload).to have_attributes(completed_at: t0, play_count: 1)
    end

    it "honours removals on Trakt, unless a change of Stream's is on its way" do
      rating = Rating.create!(profile: profile, rateable: heat, value: 8, rated_at: t0 - 1.day)
      item = PlaylistItem.create!(playlist: Playlist.watch_later_for(profile), item: ronin, position: 1)
      trakt_get("/sync/last_activities", activities("movies" => { "rated_at" => "b", "watchlisted_at" => "b" }))
      %w[movies shows episodes].each { |type| trakt_get("/sync/ratings/#{type}", []) }
      %w[movies episodes].each { |type| trakt_get("/sync/watchlist/#{type}", []) }
      TraktChange.create!(trakt_account: account, action: "watchlist_add", item: ronin, created_at: Time.current)

      Trakt::Pull.new(account).call

      expect { rating.reload }.to raise_error(ActiveRecord::RecordNotFound)
      expect(item.reload).to be_persisted
      expect(account.reload.synced_keys).to eq("ratings" => [], "watchlist" => [])
    end
  end

  it "syncs now from Settings, and not for a profile that isn't linked" do
    post "/api/v1/trakt_account/sync", headers: auth_headers(user).merge(profile_header(profile))
    expect(response).to have_http_status(:accepted)
    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("TraktPullJob", "TraktPushJob")

    other = Profile.create!(household: household, name: "Guest")
    post "/api/v1/trakt_account/sync", headers: auth_headers(user).merge(profile_header(other))
    expect(response).to have_http_status(:conflict)
  end

  it "fans out a pull for every linked account" do
    TraktAccount.create!(household: household, profile: Profile.create!(household: household, name: "Pending"), state: "pending")
    TraktSyncJob.perform_now
    expect(enqueued_jobs.select { |job| job["job_class"] == "TraktPullJob" }.map { |job| job["arguments"] }).to eq([ [ account.id ] ])
  end
end
