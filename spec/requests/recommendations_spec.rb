# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Recommendations and smart collections", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:headers) { auth_headers(admin) }
  let!(:profile) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root, name: "Movies") }
  let(:mann) { Person.create!(name: "Michael Mann", tmdb_id: 1) }
  let(:pacino) { Person.create!(name: "Al Pacino", tmdb_id: 2) }

  def movie(title, year:, genres:, overview:, people: [], rating: 7.0, height: 1080)
    Movie.create!(household: household, library: library, title: title, year: year, genres: genres, overview: overview,
      vote_average: rating).tap do |movie|
      file = MediaFile.create!(household: household, library: library, path: "/m/#{title}.mkv", size: 1, mtime: Time.current, state: "probed")
      file.media_streams.create!(index: 0, kind: "video", codec: "hevc", height: height, hdr_format: height > 2000 ? "hdr10" : nil)
      movie.editions.create!(media_file: file)
      people.each { |person, role| movie.credits.create!(person: person, role: role) }
    end
  end

  let!(:heat) { movie("Heat", year: 1995, genres: %w[Crime Thriller], overview: "A master thief and a detective in Los Angeles.", people: [ [ mann, "director" ], [ pacino, "cast" ] ]) }
  let!(:collateral) { movie("Collateral", year: 2004, genres: %w[Crime Thriller], overview: "A hitman and a taxi driver in Los Angeles.", people: [ [ mann, "director" ] ]) }
  let!(:paddington) { movie("Paddington", year: 2014, genres: %w[Family Comedy], overview: "A bear from Peru finds a family in London.", rating: 7.3, height: 2160) }

  before { EmbedTitlesJob.perform_now }

  it "finds what's like a title by what it's made of" do
    get "/api/v1/movies/#{heat.id}/similar", headers: headers
    expect(json.map { |card| card["title"] }.first).to eq("Collateral")
    expect(json.map { |card| card["title"] }).not_to include("Heat")
  end

  it "gives a title in Because you watched its real progress and what's left of a show" do
    tv = create_library(household: household, roots: build_root, kind: "shows", name: "TV")
    series = ->(title) do
      Show.create!(household: household, library: tv, folder: title, title: title, genres: %w[Crime Thriller],
        overview: "A hitman and a thief in Los Angeles.").tap do |show|
        season = show.seasons.create!(season_number: 1)
        episode = show.episodes.create!(season: season, season_number: 1, episode_number: 1, title: "#{title} 1")
        file = MediaFile.create!(household: household, library: tv, path: "/tv/#{title}.mkv", size: 1, mtime: Time.current, state: "probed")
        episode.editions.create!(media_file: file)
      end
    end
    finished = series.call("The Finished")
    %w[Heist Cartel Precinct].each { |title| series.call(title) }
    EmbedTitlesJob.perform_now
    Playback::Progress.mark(profile, finished.episodes.first, watched: true)

    get "/api/v1/home", headers: headers
    row = json["hubs"].find { |hub| hub["title"] == "Because you watched The Finished" }
    expect(row["items"].find { |card| card["title"] == "Heist" }).to include("unwatched_count" => 1)
  end

  it "offers Because you watched on Home, without what's already been watched" do
    Playback::Progress.mark(profile, heat, watched: true)
    movie("Thief", year: 1981, genres: %w[Crime Thriller], overview: "A safecracker in Chicago.", people: [ [ mann, "director" ] ])
    movie("Miami Vice", year: 2006, genres: %w[Crime Thriller], overview: "Two detectives undercover in Miami.", people: [ [ mann, "director" ] ])
    EmbedTitlesJob.perform_now

    get "/api/v1/home", headers: headers
    row = json["hubs"].find { |hub| hub["title"] == "Because you watched Heat" }
    expect(row["items"].map { |card| card["title"] }).to include("Collateral", "Thief", "Miami Vice")
    expect(row["items"].map { |card| card["title"] }).not_to include("Heat")
  end

  it "keeps a smart collection's rules and works it out for whoever looks" do
    post "/api/v1/collections", params: { kind: "smart", title: "Unwatched crime", rules: { genres: [ "Crime" ], unwatched: true, sort: "year" } },
      headers: headers
    id = json["id"]
    Playback::Progress.mark(profile, collateral, watched: true)

    get "/api/v1/collections/#{id}", headers: headers
    expect(json).to include("collection_kind" => "smart")
    expect(json["rules"]).to include("genres" => [ "Crime" ], "unwatched" => true, "sort" => "year")
    expect(json["items"].map { |card| card["title"] }).to eq(%w[Heat])

    patch "/api/v1/collections/#{id}", params: { rules: { uhd: true } }, headers: headers
    get "/api/v1/collections/#{id}", headers: headers
    expect(json["items"].map { |card| card["title"] }).to eq(%w[Paddington])
  end
end
