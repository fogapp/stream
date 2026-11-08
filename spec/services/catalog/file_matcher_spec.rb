# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Catalog::FileMatcher do
  let(:household) { Household.create!(name: "Match") }
  let(:movies_root) { build_root }
  let(:shows_root) { build_root }
  let(:movies) { create_library(household: household, roots: movies_root, name: "Movies") }
  let(:shows) { create_library(household: household, roots: shows_root, kind: "shows", name: "TV") }

  def probed_file(library, relative, height: 1080)
    file = MediaFile.create!(household: household, library: library, path: File.join(library.roots.first, relative),
      size: 1, mtime: Time.current, state: "probed")
    file.media_streams.create!(index: 0, kind: "video", codec: "h264", width: height * 16 / 9, height: height)
    file
  end

  def match(file) = described_class.new(file).call

  describe "movies without a TMDB key" do
    it "files the movie under its parsed name, unmatched but playable" do
      file = probed_file(movies, "Heat (1995)/heat.1995.1080p.bluray.mkv")
      match(file)

      movie = Movie.sole
      expect(movie).to have_attributes(title: "Heat", year: 1995, match_state: "unmatched", sort_title: "heat")
      expect(movie.media_files).to eq([ file ])
      expect(movie.editions.sole.name).to eq("1080p")
      expect(file.analysis_runs.sole).to have_attributes(step: "match", status: "succeeded", tool_version: "filename")
    end

    it "collapses two versions of the same film into one movie" do
      match(probed_file(movies, "Heat (1995)/Heat (1995).mkv"))
      match(probed_file(movies, "Heat (1995)/Heat (1995) 4K.mkv", height: 2160))

      expect(Movie.count).to eq(1)
      expect(Movie.sole.editions.map(&:name)).to contain_exactly("1080p", "4K")
    end

    it "finds the film a second version names by its normalized title, without reading every film of that year" do
      12.times { |n| Movie.create!(household: household, library: movies, title: "Other #{n}", year: 1995) }
      film = Movie.create!(household: household, library: movies, title: "The Heat & Dust", year: 1995)
      expect(film.normalized_title).to eq("heat and dust")
      # Written by a replica on older code, before the column: still found.
      older = Movie.create!(household: household, library: movies, title: "Ronin", year: 1998)
      older.update_column(:normalized_title, nil) # rubocop:disable Rails/SkipsModelValidations

      reads = count_queries(matching: /FROM "movies"/) { match(probed_file(movies, "Heat & Dust (1995)/Heat and Dust (1995) 4K.mkv", height: 2160)) }
      match(probed_file(movies, "Ronin (1998)/Ronin (1998).mkv"))

      expect(film.editions.reload.map(&:name)).to eq([ "4K" ])
      expect(older.editions.reload.size).to eq(1)
      expect(Movie.count).to eq(14)
      expect(reads.grep(/"year" = /).grep_v(/normalized_title/)).to be_empty
    end

    it "keeps different films in one folder apart" do
      match(probed_file(movies, "Alien Collection/Alien (1979).mkv"))
      match(probed_file(movies, "Alien Collection/Aliens (1986).mkv"))
      expect(Movie.order(:year).pluck(:title, :year)).to eq([ [ "Alien", 1979 ], [ "Aliens", 1986 ] ])
    end

    it "attaches extras to the film beside them, whichever is read first" do
      trailer = probed_file(movies, "Heat (1995)/Heat (1995)-trailer.mkv")
      match(trailer)
      expect(Movie.count).to eq(0)
      expect(Extra.sole).to have_attributes(kind: "trailer", title: "Heat", owner: nil)

      match(probed_file(movies, "Heat (1995)/Heat (1995).mkv"))
      match(probed_file(movies, "Heat (1995)/Featurettes/Making Heat.mkv"))

      heat = Movie.sole
      expect(heat.extras.order(:kind).map { |extra| [ extra.kind, extra.title ] })
        .to eq([ %w[featurette Making\ Heat], %w[trailer Heat] ])
      expect(heat.media_files.count).to eq(1)
    end

    it "gives a loose extra in the root only to the film it names" do
      match(probed_file(movies, "Heat (1995).mkv"))
      match(probed_file(movies, "Primer (2004).mkv"))
      match(probed_file(movies, "Primer-trailer.mkv"))
      expect(Extra.sole.owner.title).to eq("Primer")
    end
  end

  describe "show extras" do
    it "attaches to the season whose folder holds it, else the show" do
      match(probed_file(shows, "Severance/Season 1/Severance S01E01.mkv"))
      match(probed_file(shows, "Severance/Season 1/Behind the Scenes/Making the Office.mkv"))
      match(probed_file(shows, "Severance/Trailers/Season 2 Teaser.mkv"))

      show = Show.sole
      expect(show.extras.map(&:title)).to eq([ "Season 2 Teaser" ])
      expect(show.seasons.find_by(season_number: 1).extras.sole).to have_attributes(kind: "behind_the_scenes", title: "Making the Office")
    end
  end

  describe "movies with TMDB" do
    before { configure_tmdb(household) }

    it "matches a clear search result and freezes its metadata and credits" do
      stub_tmdb("/search/movie", { "results" => [ tmdb_movie(id: 949, title: "Heat", date: "1995-12-15", popularity: 30) ] })
      stub_tmdb("/movie/949", tmdb_movie(id: 949, title: "Heat", date: "1995-12-15"))

      match(probed_file(movies, "Heat (1995)/Heat (1995).mkv"))

      movie = Movie.sole
      expect(movie).to have_attributes(tmdb_id: 949, match_state: "matched", content_rating: "R", runtime_minutes: 120,
        genres: [ "Drama" ], poster_path: "/p949.jpg", logo_path: "/l949.png", imdb_id: "tt0000949")
      expect(movie.match_reasons["summary"]).to include("year matches")
      expect(movie.credits.map { |credit| [ credit.person.name, credit.role ] })
        .to eq([ [ "Al Pacino", "cast" ], [ "Michael Mann", "director" ] ])
    end

    it "goes straight to the id in the folder name without searching" do
      stub_tmdb("/movie/348", tmdb_movie(id: 348, title: "Alien", date: "1979-05-25"))

      match(probed_file(movies, "Alien (1979) {tmdb-348}/Alien.mkv"))

      expect(Movie.sole).to have_attributes(tmdb_id: 348, match_state: "matched")
      expect(a_request(:get, %r{/search/})).not_to have_been_made
    end

    it "asks a person when two candidates fit equally well" do
      stub_tmdb("/search/movie", { "results" => [
        tmdb_movie(id: 438_631, title: "Dune", date: "2021-09-15", popularity: 90),
        tmdb_movie(id: 841, title: "Dune", date: "1984-12-14", popularity: 20)
      ] })

      match(probed_file(movies, "Dune/Dune.mkv"))

      movie = Movie.sole
      expect(movie.match_state).to eq("needs_review")
      expect(movie.match_candidates.map { |candidate| candidate["tmdb_id"] }).to eq([ 438_631, 841 ])
      expect(movie.match_reasons["summary"]).to include("fit equally well")
      expect(movie.media_files.count).to eq(1)
    end

    it "settles a tie on the candidate with a landslide of TMDB votes" do
      stub_tmdb("/search/movie", { "results" => [
        tmdb_movie(id: 1984, title: "Shameless", date: "2004-01-13", vote_count: 161),
        tmdb_movie(id: 2011, title: "Shameless", date: "2011-01-09", vote_count: 3517),
        tmdb_movie(id: 2017, title: "Shameless", date: "2017-03-01", vote_count: 5)
      ] })
      stub_tmdb("/movie/2011", tmdb_movie(id: 2011, title: "Shameless", date: "2011-01-09"))

      match(probed_file(movies, "Shameless/Shameless.mkv"))

      movie = Movie.sole
      expect(movie).to have_attributes(tmdb_id: 2011, match_state: "matched")
      expect(movie.match_reasons["summary"]).to include("3,517 TMDB votes to 161 for Shameless (2004)")
    end

    it "still asks when the tied candidates' votes are close, or too few to mean much" do
      stub_tmdb("/search/movie", { "results" => [
        tmdb_movie(id: 438_631, title: "Dune", date: "2021-09-15", vote_count: 15_614),
        tmdb_movie(id: 841, title: "Dune", date: "1984-12-14", vote_count: 4_200)
      ] })
      stub_tmdb("/search/tv", { "results" => [
        { "id" => 1, "name" => "Starstruck", "first_air_date" => "2021-06-08", "vote_count" => 12 },
        { "id" => 2, "name" => "Starstruck", "first_air_date" => "2022-01-01", "vote_count" => 1 }
      ] })

      match(probed_file(movies, "Dune/Dune.mkv"))
      match(probed_file(shows, "Starstruck/Season 1/Starstruck - S01E01.mkv"))

      expect(Movie.sole.match_state).to eq("needs_review")
      expect(Show.sole.match_state).to eq("needs_review")
    end

    it "merges a second copy into the movie that already holds that TMDB id" do
      stub_tmdb("/search/movie", { "results" => [ tmdb_movie(id: 949, title: "Heat", date: "1995-12-15") ] })
      stub_tmdb("/movie/949", tmdb_movie(id: 949, title: "Heat", date: "1995-12-15"))
      match(probed_file(movies, "Heat (1995)/Heat (1995).mkv"))
      match(probed_file(movies, "Other/heat.1995.2160p.mkv", height: 2160))

      expect(Movie.count).to eq(1)
      expect(Movie.sole.editions.count).to eq(2)
    end

    it "never overwrites a field a person locked" do
      stub_tmdb("/search/movie", { "results" => [ tmdb_movie(id: 949, title: "Heat", date: "1995-12-15") ] })
      stub_tmdb("/movie/949", tmdb_movie(id: 949, title: "Heat", date: "1995-12-15"))
      file = probed_file(movies, "Heat (1995)/Heat (1995).mkv")
      Movie.create!(household: household, library: movies, title: "Heat (Director's Preference)", year: 1995,
        locked_fields: [ "title" ]).editions.create!(media_file: file)

      match(file)
      expect(Movie.sole).to have_attributes(title: "Heat (Director's Preference)", tmdb_id: 949)
    end
  end

  describe "shows" do
    it "groups episodes by show folder and numbers them without a key" do
      match(probed_file(shows, "Severance/Season 01/Severance - S01E01.mkv"))
      match(probed_file(shows, "Severance/Season 01/Severance - S01E02.mkv"))

      show = Show.sole
      expect(show).to have_attributes(title: "Severance", folder: "Severance", match_state: "unmatched")
      expect(show.episodes.map(&:code)).to eq(%w[S01E01 S01E02])
      expect(show.seasons.sole.display_title).to eq("Season 1")
    end

    it "gives a two-episode file both episodes" do
      match(probed_file(shows, "The Office (US)/Season 3/The.Office.US.S03E01E02.mkv"))
      expect(Show.sole.episodes.map(&:code)).to eq(%w[S03E01 S03E02])
      expect(Edition.count).to eq(2)
    end

    it "matches the show once, fills the season from TMDB once, and links files to real episodes" do
      configure_tmdb(household)
      stub_tmdb("/search/tv", { "results" => [ { "id" => 95_396, "name" => "Severance", "first_air_date" => "2022-02-17" } ] })
      stub_tmdb("/tv/95396", tmdb_show(id: 95_396, name: "Severance", date: "2022-02-17"))
      season = stub_tmdb("/tv/95396/season/1", tmdb_season(1, { 1 => "Good News About Hell", 2 => "Half Loop" }))

      match(probed_file(shows, "Severance (2022)/Season 1/Severance.S01E01.mkv"))
      match(probed_file(shows, "Severance (2022)/Season 1/Severance.S01E02.mkv"))

      show = Show.sole
      expect(show).to have_attributes(tmdb_id: 95_396, match_state: "matched", network: "Apple TV+", tvdb_id: 371_980,
        content_rating: "TV-MA")
      expect(show.episodes.map { |episode| [ episode.code, episode.title ] })
        .to eq([ %w[S01E01 Good\ News\ About\ Hell], %w[S01E02 Half\ Loop] ])
      expect(show.episodes.flat_map(&:media_files).size).to eq(2)
      expect(show.credits.sole).to have_attributes(role: "creator")
      expect(season).to have_been_requested.once
    end

    it "records a file it can't place as a failed match step" do
      file = probed_file(shows, "Severance/Severance - Behind it all.mkv")
      expect { match(file) }.to raise_error(described_class::Unplaceable)
      expect(file.analysis_runs.sole).to have_attributes(step: "match", status: "failed", error: include("season and episode"))
    end
  end
end
