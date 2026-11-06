# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Metadata editing", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:movie) do
    Movie.create!(household: household, library: library, title: "Heat", year: 1995, tmdb_id: 949, match_state: "matched",
      overview: "From TMDB.", genres: %w[Crime])
  end

  it "saves what changed and locks just those fields, so a refresh leaves them be" do
    patch "/api/v1/metadata/movie/#{movie.id}", params: { changes: { title: "Heat (Director's Cut)", overview: "From TMDB.",
      genres: "Crime, Thriller", year: "1995" } }, headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:ok)
    expect(json).to include("title" => "Heat (Director's Cut)", "genres" => %w[Crime Thriller], "locked_fields" => %w[genres title])

    Catalog::Metadata.apply_movie(movie.reload, tmdb_movie(id: 949, title: "Heat", date: "1995-12-15"))
    expect(movie.reload).to have_attributes(title: "Heat (Director's Cut)", genres: %w[Crime Thriller], overview: "About Heat.")
  end

  it "hands an unlocked field back to TMDB and refreshes" do
    movie.update!(title: "Mine", locked_fields: %w[title])
    configure_tmdb(household)
    stub_tmdb("/movie/949", tmdb_movie(id: 949, title: "Heat", date: "1995-12-15"))

    perform_enqueued_jobs(only: RefreshMetadataJob) do
      patch "/api/v1/metadata/movie/#{movie.id}", params: { unlock: [ "title" ] }, headers: auth_headers(admin), as: :json
    end

    expect(movie.reload).to have_attributes(title: "Heat", locked_fields: [])
  end

  it "edits an episode, and says what's wrong with a bad date" do
    show = Show.create!(household: household, library: library, folder: "Severance", title: "Severance")
    episode = show.episodes.create!(season: show.seasons.create!(season_number: 1), season_number: 1, episode_number: 1)

    patch "/api/v1/metadata/episode/#{episode.id}", params: { changes: { title: "Good News About Hell", air_date: "2022-02-18" } },
      headers: auth_headers(admin), as: :json
    expect(json).to include("title" => "Good News About Hell", "air_date" => "2022-02-18", "locked_fields" => %w[air_date title])

    patch "/api/v1/metadata/episode/#{episode.id}", params: { changes: { air_date: "someday" } }, headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("date")
  end

  it "is for admins only" do
    patch "/api/v1/metadata/movie/#{movie.id}", params: { changes: { title: "x" } }, headers: auth_headers(create_user(household: household)),
      as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
