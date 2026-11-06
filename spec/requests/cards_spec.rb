# typed: false
# frozen_string_literal: true

require "rails_helper"

# Viewing::Cards: a card says the same whichever page it's on.
RSpec.describe "Title cards", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let!(:headers) { auth_headers(admin) }
  let!(:profile) { Profile.default_for(household) }
  let(:films) { create_library(household: household, roots: build_root, name: "Films") }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def file(library, state: "probed")
    MediaFile.create!(household: household, library: library, path: "/m/#{SecureRandom.hex(4)}.mkv", size: 1, mtime: Time.current, state: state,
      duration_seconds: 1200)
  end

  def movie(title, state: "probed")
    Movie.create!(household: household, library: films, title: title).tap { |film| film.editions.create!(media_file: file(films, state: state)) }
  end

  def resume(playable, at)
    WatchState.create!(profile: profile, playable: playable, position_seconds: 300, duration_seconds: 1200, last_watched_at: at)
  end

  it "tells search how much of a show is left" do
    series = Show.create!(household: household, library: tv, folder: "Severance", title: "Severance")
    season = series.seasons.create!(season_number: 1)
    series.episodes.create!(season: season, season_number: 1, episode_number: 1, title: "Good News").editions.create!(media_file: file(tv))

    get "/api/v1/search", params: { q: "severance" }, headers: headers

    expect(json["shows"].sole).to include("title" => "Severance", "unwatched_count" => 1)
  end

  it "fills Continue watching with what can be played, however much newer what can't is" do
    20.times { |i| resume(movie("Gone #{i}", state: "missing"), i.minutes.ago) }
    kept = movie("Heat")
    resume(kept, 1.hour.ago)

    get "/api/v1/home", headers: headers

    row = json["hubs"].find { |hub| hub["key"] == "continue_watching" }
    expect(row["items"].pluck("title")).to eq([ "Heat" ])
    expect(row["items"].sole).to include("progress" => 0.25, "watched" => false)
  end

  it "keeps what a restricted profile may not see out of Continue watching without shortening it" do
    younger = Profile.create!(household: household, name: "Younger", max_rating_age: 10, position: 1)
    allowed = Movie.create!(household: household, library: films, title: "Paddington", content_rating: "PG")
    allowed.editions.create!(media_file: file(films))
    barred = Array.new(20) do |i|
      Movie.create!(household: household, library: films, title: "Alien #{i}", content_rating: "R").tap { |film| film.editions.create!(media_file: file(films)) }
    end
    barred.each_with_index { |film, i| WatchState.create!(profile: younger, playable: film, position_seconds: 300, duration_seconds: 1200, last_watched_at: i.minutes.ago) }
    WatchState.create!(profile: younger, playable: allowed, position_seconds: 300, duration_seconds: 1200, last_watched_at: 1.hour.ago)

    get "/api/v1/home", headers: headers.merge(profile_header(younger))

    expect(json["hubs"].find { |hub| hub["key"] == "continue_watching" }["items"].pluck("title")).to eq([ "Paddington" ])
  end
end
