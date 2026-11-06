# typed: false
# frozen_string_literal: true

require "rails_helper"

# Real-world names as they arrive from Radarr, Sonarr, rippers and scene
# releases (PROPOSAL §5.2). Add a row whenever a name is misread in the wild.
RSpec.describe Media::NameParser do
  movies = Library::Kind::Movies
  shows = Library::Kind::Shows

  MOVIES = {
    "Heat (1995)/Heat (1995).mkv" => { title: "Heat", year: 1995 },
    "Heat (1995)/heat.1995.1080p.bluray.x264-sparks.mkv" => { title: "Heat", year: 1995 },
    "The.Matrix.1999.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-EPSiLON.mkv" => { title: "The Matrix", year: 1999 },
    "Blade Runner 2049 (2017) [imdbid-tt1856101].mkv" => { title: "Blade Runner 2049", year: 2017, imdb_id: "tt1856101" },
    "2001 A Space Odyssey (1968)/2001 A Space Odyssey (1968).mkv" => { title: "2001 A Space Odyssey", year: 1968 },
    "Alien (1979) {tmdb-348}/Alien (1979) {edition-Director's Cut}.mkv" => { title: "Alien", year: 1979, tmdb_id: 348, edition: "Director's Cut" },
    "Aliens.1986.Extended.Cut.1080p.BluRay.mkv" => { title: "Aliens", year: 1986, edition: "Extended" },
    "Mr. Nobody (2009).mp4" => { title: "Mr. Nobody", year: 2009 },
    "Amélie (2001)/Amélie.mkv" => { title: "Amélie", year: 2001 },
    "Some_Home_Movie_1080p.mkv" => { title: "Some Home Movie", year: nil },
    "Primer.mkv" => { title: "Primer", year: nil },
    "Movies/Dune Part Two (2024)/Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265.mkv" => { title: "Dune Part Two", year: 2024 }
  }.freeze

  EPISODES = {
    "Severance/Season 02/Severance - S02E03 - Who Is Alive.mkv" => { title: "Severance", season: 2, episodes: [ 3 ] },
    "Severance (2022)/Season 1/Severance.S01E01.1080p.WEB.mkv" => { title: "Severance", year: 2022, season: 1, episodes: [ 1 ] },
    "The Office (US)/Season 3/The.Office.US.S03E01E02.mkv" => { title: "The Office (US)", season: 3, episodes: [ 1, 2 ] },
    "Friends/Season 01/Friends - 1x05 - The One with the East German Laundry Detergent.avi" => { title: "Friends", season: 1, episodes: [ 5 ] },
    "Show/Season 1/Show - S01E01-E03.mkv" => { title: "Show", season: 1, episodes: [ 1, 2, 3 ] },
    "Doctor Who (2005)/Specials/Doctor Who (2005) - S00E01 - The Christmas Invasion.mkv" => { title: "Doctor Who", year: 2005, season: 0, episodes: [ 1 ] },
    "The Daily Show/Season 2024/The Daily Show - 2024-01-31 - Guest.mkv" => { title: "The Daily Show", season: 2024, air_date: Date.new(2024, 1, 31) },
    "Bluey (2018) {tvdb-353546}/Season 1/Bluey S01E01 Magic Xylophone.mp4" => { title: "Bluey", year: 2018, tvdb_id: 353_546, season: 1, episodes: [ 1 ] },
    "Planet Earth/Episode 04.mkv" => { title: "Planet Earth", season: 1, episodes: [ 4 ] },
    "Mr. Robot/Season 2/mr.robot.s02e12.720p.mkv" => { title: "Mr. Robot", season: 2, episodes: [ 12 ] }
  }.freeze

  EXTRAS = {
    "Heat (1995)/Heat (1995)-trailer.mkv" => "trailer",
    "Heat (1995)/Featurettes/Making Heat.mkv" => "featurette",
    "Heat (1995)/Behind The Scenes/Crew.mkv" => "behind_the_scenes",
    "Severance/Season 01/Extras/Table read.mkv" => "other"
  }.freeze

  NOT_EXTRAS = {
    "Other/Heat (1995).mkv" => "Heat",
    "Trailers/Blade Runner (1982).mkv" => "Blade Runner"
  }.freeze

  describe "movies" do
    MOVIES.each do |path, want|
      it path do
        parsed = described_class.parse(path, movies)
        expect(parsed.kind).to eq(described_class::Kind::Movie)
        want.each { |key, value| expect(parsed.public_send(key)).to eq(value), "#{key}: #{parsed.public_send(key).inspect}" }
      end
    end
  end

  describe "episodes" do
    EPISODES.each do |path, want|
      it path do
        parsed = described_class.parse(path, shows)
        expect(parsed.kind).to eq(described_class::Kind::Episode)
        expect(parsed.show_folder).to eq(path.split("/").first)
        want.each { |key, value| expect(parsed.public_send(key)).to eq(value), "#{key}: #{parsed.public_send(key).inspect}" }
      end
    end
  end

  describe "extras" do
    EXTRAS.each do |path, kind|
      it path do
        library = path.start_with?("Severance") ? shows : movies
        parsed = described_class.parse(path, library)
        expect(parsed).to have_attributes(kind: described_class::Kind::Extra, extra_kind: kind)
      end
    end
  end

  describe "folders named like extras folders at the top level" do
    NOT_EXTRAS.each do |path, title|
      it path do
        expect(described_class.parse(path, movies)).to have_attributes(kind: described_class::Kind::Movie, title: title)
      end
    end
  end

  describe ".normalize" do
    it "ignores case, accents, punctuation, ampersands and a leading article" do
      expect(described_class.normalize("The Lord of the Rings: The Return of the King"))
        .to eq("lord of the rings the return of the king")
      expect(described_class.normalize("Amélie")).to eq(described_class.normalize("amelie"))
      expect(described_class.normalize("Law & Order")).to eq(described_class.normalize("Law and Order"))
    end
  end
end
