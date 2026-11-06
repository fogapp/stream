# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sending to Trakt", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:profile) { Profile.default_for(household) }
  let(:headers) { auth_headers(user).merge(profile_header(profile)) }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:movie) { Movie.create!(household: household, library: library, title: "Heat", year: 1995, tmdb_id: 949, imdb_id: "tt0113277") }
  let(:show) { Show.create!(household: household, library: library, folder: "Office", title: "The Office", tvdb_id: 73_244) }
  let(:episode) do
    season = show.seasons.create!(season_number: 2)
    show.episodes.create!(season: season, season_number: 2, episode_number: 5, title: "Halloween")
  end
  let!(:account) do
    TraktSetting.create!(household: household, client_id: "client-abc", client_secret: "secret-xyz")
    TraktAccount.create!(household: household, profile: profile, state: "linked", access_token: "at-1", refresh_token: "rt-1",
      expires_at: 1.day.from_now)
  end

  before { allow_any_instance_of(Trakt::Api).to receive(:sleep) } # rubocop:disable RSpec/AnyInstance

  def trakt(path, body = nil)
    stub = stub_request(:post, "https://api.trakt.tv#{path}")
    stub = stub.with(body: body) if body
    stub.to_return(status: 201, body: "{}")
  end

  it "sends marking watched and unwatched, a movie and an episode by its show" do
    freeze_time do
      added = []
      stub_request(:post, "https://api.trakt.tv/sync/history").to_return do |request|
        added << JSON.parse(request.body)
        { status: 201, body: "{}" }
      end
      remove = trakt("/sync/history/remove", { movies: [ { ids: { tmdb: 949, imdb: "tt0113277" } } ] })

      post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: movie.id }, headers: headers
      post "/api/v1/watch_states", params: { playable_type: "episode", playable_id: episode.id }, headers: headers
      # Already watched: not another play.
      post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: movie.id }, headers: headers
      post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: movie.id, watched: false }, headers: headers
      perform_enqueued_jobs

      now = Time.current.utc.iso8601
      expect(added.flat_map { |body| body.fetch("movies", []) }).to eq([ { "watched_at" => now, "ids" => { "tmdb" => 949, "imdb" => "tt0113277" } } ])
      expect(added.flat_map { |body| body.fetch("shows", []) })
        .to eq([ { "ids" => { "tvdb" => 73_244 }, "seasons" => [ { "number" => 2, "episodes" => [ { "watched_at" => now, "number" => 5 } ] } ] } ])
      expect(remove).to have_been_requested.once
      expect(TraktChange.count).to eq(0)
      expect(account.reload.last_synced_at).to eq(Time.current)
    end
  end

  it "sends only the last word on a rating, in Trakt's whole stars" do
    set = trakt("/sync/ratings", { movies: [ { rating: 9, ids: { tmdb: 949, imdb: "tt0113277" } } ] })
    put "/api/v1/rating", params: { rateable_type: "movie", rateable_id: movie.id, value: 4 }, headers: headers
    put "/api/v1/rating", params: { rateable_type: "movie", rateable_id: movie.id, value: 8.5 }, headers: headers
    perform_enqueued_jobs
    expect(set).to have_been_requested.once
  end

  it "keeps Watch later and the Trakt watchlist in step" do
    add = trakt("/sync/watchlist", { movies: [ { ids: { tmdb: 949, imdb: "tt0113277" } } ] })
    remove = trakt("/sync/watchlist/remove", { movies: [ { ids: { tmdb: 949, imdb: "tt0113277" } } ] })
    post "/api/v1/watch_later", params: { item_type: "movie", item_id: movie.id }, headers: headers
    perform_enqueued_jobs
    delete "/api/v1/watch_later", params: { item_type: "movie", item_id: movie.id }, headers: headers
    perform_enqueued_jobs
    expect(add).to have_been_requested.once
    expect(remove).to have_been_requested.once
  end

  it "records nothing for a profile that isn't linked, or a title Trakt can't name" do
    other = Profile.create!(household: household, name: "Guest")
    post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: movie.id }, headers: auth_headers(user).merge(profile_header(other))
    unmatched = Movie.create!(household: household, library: library, title: "Home movie")
    post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: unmatched.id }, headers: headers
    expect(TraktChange.count).to eq(0)
  end

  it "says why Trakt refused, and keeps the change to try again" do
    stub_request(:post, "https://api.trakt.tv/sync/watchlist").to_return(status: 420, body: "")
    post "/api/v1/watch_later", params: { item_type: "movie", item_id: movie.id }, headers: headers
    perform_enqueued_jobs
    expect(TraktChange.sole).to have_attributes(attempts: 1, last_error: include("watchlist"))
    expect(account.reload.last_error).to include("Couldn't send 1 change")
  end

  it "refreshes a token about to run out, and asks for a new link when Trakt won't" do
    account.update!(expires_at: 10.minutes.from_now)
    stub_request(:post, "https://api.trakt.tv/oauth/token").with(body: hash_including(refresh_token: "rt-1", grant_type: "refresh_token"))
      .to_return(status: 200, body: { access_token: "at-2", refresh_token: "rt-2", expires_in: 86_400, created_at: Time.current.to_i }.to_json)
    add = stub_request(:post, "https://api.trakt.tv/sync/history").with(headers: { "Authorization" => "Bearer at-2" })
      .to_return(status: 201, body: "{}")
    post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: movie.id }, headers: headers
    perform_enqueued_jobs
    expect(add).to have_been_requested
    expect(account.reload).to have_attributes(access_token: "at-2", refresh_token: "rt-2")

    account.update!(expires_at: 10.minutes.from_now)
    stub_request(:post, "https://api.trakt.tv/oauth/token").to_return(status: 401, body: "")
    post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: movie.id, watched: false }, headers: headers
    perform_enqueued_jobs
    expect(account.reload.state).to eq("needs_relink")
    expect(ActivityEntry.where(event: "trakt.unlinked")).to exist
  end
end
