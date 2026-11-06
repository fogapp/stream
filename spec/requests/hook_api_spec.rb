# typed: false
# frozen_string_literal: true

require "rails_helper"

# What Hook — the household's acquisition engine — reads from Stream to look
# after what it delivers (Hook docs/stream-tv-handoff.md): titles by their
# ids elsewhere, a show's whole inventory, where the household is in a show,
# whether an episode sounds like its show, and files by content or place.
RSpec.describe "Hook's API", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let!(:everyone) { Profile.default_for(household) }
  let(:kid) { Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 10) }
  let(:films) { create_library(household: household, roots: build_root, name: "Films") }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def media_file(library, name, state: "probed", fingerprint: nil, size: 1)
    MediaFile.create!(household: household, library: library, path: File.join(library.roots.first, name), size: size,
      mtime: Time.current, state: state, fingerprint: fingerprint, duration_seconds: 1800)
  end

  def film(title, rating: "PG", **ids)
    Movie.create!(household: household, library: films, title: title, content_rating: rating, **ids).tap do |movie|
      movie.editions.create!(media_file: media_file(films, "#{title}.mkv"))
    end
  end

  # Episodes as [season, number, has_file]: Stream knows some from TMDB only.
  def series(title, episodes, rating: "TV-PG", **ids)
    show = Show.create!(household: household, library: tv, folder: title, title: title, content_rating: rating, **ids)
    episodes.each do |season_number, number, with_file|
      season = show.seasons.find_or_create_by!(season_number: season_number)
      episode = show.episodes.create!(season: season, season_number: season_number, episode_number: number,
        title: "#{title} #{season_number}x#{number}", air_date: Date.new(2022, 2, 18) + number.weeks)
      episode.editions.create!(media_file: media_file(tv, "#{title}/S#{season_number}E#{number}.mkv")) if with_file
    end
    show
  end

  def episode(show, season_number, number) = show.episodes.find_by!(season_number: season_number, episode_number: number)

  def watched(profile, playable, at: Time.current)
    Playback::Progress.mark(profile, playable, watched: true).tap { |state| state.update!(last_watched_at: at) }
  end

  describe "titles by their ids elsewhere" do
    it "finds shows by TMDB, TVDB or IMDb id, OR'd, with every card carrying them" do
      severance = series("Severance", [ [ 1, 1, true ] ], tmdb_id: 95_396, tvdb_id: 371_980, imdb_id: "tt11280740")
      andor = series("Andor", [ [ 1, 1, true ] ], tmdb_id: 83_867)
      series("Barry", [ [ 1, 1, true ] ], tmdb_id: 73_107)

      get "/api/v1/shows", params: { tmdb_id: "95396" }, headers: auth_headers(admin)
      expect(json.sole).to include("id" => severance.id, "tmdb_id" => 95_396, "tvdb_id" => 371_980, "imdb_id" => "tt11280740")

      get "/api/v1/shows", params: { tvdb_id: "371980", imdb_id: "tt0000001" }, headers: auth_headers(admin)
      expect(json.map { |card| card["id"] }).to eq([ severance.id ])

      get "/api/v1/shows", params: { tmdb_id: "83867,95396" }, headers: auth_headers(admin)
      expect(json.map { |card| card["id"] }).to eq([ andor.id, severance.id ])

      get "/api/v1/shows", params: { imdb_id: "tt11280740", tmdb_id: "83867" }, headers: auth_headers(admin)
      expect(json.map { |card| card["id"] }).to eq([ andor.id, severance.id ])

      # An id filter that names nothing usable finds nothing, not everything.
      get "/api/v1/shows", params: { tmdb_id: "abc" }, headers: auth_headers(admin)
      expect(json).to eq([])

      get "/api/v1/shows", headers: auth_headers(admin)
      expect(json.size).to eq(3)
      expect(json.first.keys).to include("tmdb_id", "tvdb_id", "imdb_id")
    end

    it "finds movies by TMDB or IMDb id, with every card carrying them" do
      heat = film("Heat", tmdb_id: 949, imdb_id: "tt0113277")
      alien = film("Alien", tmdb_id: 348, imdb_id: "tt0078748")

      get "/api/v1/movies", params: { tmdb_id: "949" }, headers: auth_headers(admin)
      expect(json.sole).to include("id" => heat.id, "tmdb_id" => 949, "imdb_id" => "tt0113277")

      get "/api/v1/movies", params: { tmdb_id: "949", imdb_id: "tt0078748" }, headers: auth_headers(admin)
      expect(json.map { |card| card["id"] }).to eq([ alien.id, heat.id ])
    end

    it "finds nothing by id that the profile couldn't otherwise see" do
      series("Severance", [ [ 1, 1, true ] ], rating: "TV-MA", tmdb_id: 95_396)
      film("Heat", rating: "R", tmdb_id: 949)

      get "/api/v1/shows", params: { tmdb_id: "95396" }, headers: auth_headers(admin).merge(profile_header(kid))
      expect(json).to eq([])
      get "/api/v1/movies", params: { tmdb_id: "949" }, headers: auth_headers(admin).merge(profile_header(kid))
      expect(json).to eq([])
    end
  end

  describe "a show's episode inventory" do
    let(:show) { series("Severance", [ [ 0, 1, false ], [ 1, 1, true ], [ 1, 2, true ], [ 2, 1, true ], [ 2, 2, false ] ]) }

    it "lists every episode, specials and missing ones too, and to an admin the files behind each" do
      broken = media_file(tv, "Severance/S02E02.broken.mkv", state: "broken", size: 9)
      episode(show, 2, 2).editions.create!(media_file: broken, name: "Director's Cut")

      get "/api/v1/shows/#{show.id}/episodes", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json.map { |row| [ row["season_number"], row["episode_number"], row["available"] ] })
        .to eq([ [ 0, 1, false ], [ 1, 1, true ], [ 1, 2, true ], [ 2, 1, true ], [ 2, 2, false ] ])
      expect(json.first).to include("id" => episode(show, 0, 1).id, "air_date" => "2022-02-25", "files" => [])
      expect(json[1]["files"].sole).to include("path" => File.join(tv.roots.first, "Severance/S1E1.mkv"), "size" => 1,
        "state" => "probed", "edition" => nil, "video" => nil)
      expect(json.last["files"].sole).to include("path" => broken.path, "state" => "broken", "edition" => "Director's Cut")
    end

    it "keeps files from a member and from a kid profile" do
      get "/api/v1/shows/#{show.id}/episodes", headers: auth_headers(member)
      expect(json.size).to eq(5)
      expect(json).to all(satisfy { |row| !row.key?("files") })

      get "/api/v1/shows/#{show.id}/episodes", headers: auth_headers(admin).merge(profile_header(kid))
      expect(json.size).to eq(5)
      expect(json).to all(satisfy { |row| !row.key?("files") })
    end

    it "is not there for a profile that can't see the show, nor another household" do
      mature = series("Succession", [ [ 1, 1, true ] ], rating: "TV-MA")
      get "/api/v1/shows/#{mature.id}/episodes", headers: auth_headers(admin).merge(profile_header(kid))
      expect(response).to have_http_status(:not_found)

      get "/api/v1/shows/#{show.id}/episodes", headers: auth_headers(create_user(household: create_household(name: "Other"), role: "admin"))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "where the household is in a show" do
    let(:show) do
      series("Severance", [ [ 1, 1, true ], [ 1, 2, true ], [ 1, 3, true ], [ 2, 1, true ], [ 2, 2, false ], [ 2, 3, false ] ])
    end
    let(:anna) { Profile.create!(household: household, name: "Anna") }
    let(:ben) { Profile.create!(household: household, name: "Ben") }

    it "gives each profile that watched its next episode over the whole catalog, file or not" do
      watched(anna, episode(show, 1, 1), at: 3.days.ago)
      watched(anna, episode(show, 2, 1), at: 2.days.ago)
      # Ben finished everything Stream knows of.
      show.episodes.each { |each| watched(ben, each, at: 1.day.ago) }
      WatchState.create!(profile: everyone, playable: episode(show, 1, 2), position_seconds: 300, duration_seconds: 1800,
        last_watched_at: 1.hour.ago)
      Profile.create!(household: household, name: "Never")

      get "/api/v1/shows/#{show.id}/progress", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      rows = json["profiles"].index_by { |row| row["name"] }
      expect(rows.keys).to contain_exactly(everyone.name, "Anna", "Ben")
      expect(rows["Anna"]).to include("id" => anna.id, "watched_count" => 2,
        "next_up" => { "episode_id" => episode(show, 2, 2).id, "season_number" => 2, "episode_number" => 2 })
      expect(Time.zone.parse(rows["Anna"]["last_watched_at"])).to be_within(1.second).of(2.days.ago)
      expect(rows["Ben"]).to include("watched_count" => 6, "next_up" => nil)
      expect(rows[everyone.name]).to include("watched_count" => 0,
        "next_up" => { "episode_id" => episode(show, 1, 2).id, "season_number" => 1, "episode_number" => 2 })
    end

    it "is an admin's alone, and never from a kid profile" do
      get "/api/v1/shows/#{show.id}/progress", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/shows/#{show.id}/progress", headers: auth_headers(admin).merge(profile_header(kid))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "whether an episode sounds like its show" do
    let(:seconds) { Markers::Matcher::SECONDS_PER_POINT }
    let(:theme) { noise(320) }
    let(:show) { series("Severance", (1..5).map { |number| [ 1, number, true ] }) }

    def noise(count) = Array.new(count) { rand(-(2**31)...(2**31)) }

    def file_of(number) = episode(show, 1, number).editions.first.media_file

    # An opening fingerprint, with the theme 100 points in when it has one,
    # and the intro marker detection would have left.
    def opening(number, with_theme: true, intro: with_theme)
      file = file_of(number)
      points = with_theme ? noise(100) + theme + noise(400) : noise(820)
      AudioFingerprint.create!(media_file: file, segment: "head", offset_seconds: 0.0, points: points)
      Marker.offer(file, Marker::Kind::Intro, start: 100 * seconds, finish: 420 * seconds, source: Marker::Source::Detected) if intro
    end

    def identity(number, headers: auth_headers(admin))
      get "/api/v1/episodes/#{episode(show, 1, number).id}/identity", headers: headers
      json
    end

    it "is a match when the episode's opening holds the show's theme" do
      (1..5).each { |number| opening(number) }

      expect(identity(3)).to include("intro" => "match", "compared" => 4)
      expect(identity(3)["confidence"]).to be >= 0.8
    end

    it "is a mismatch when the show shares a theme and this file's opening has none of it" do
      (1..4).each { |number| opening(number) }
      opening(5, with_theme: false)

      result = identity(5)
      expect(result).to include("intro" => "mismatch", "compared" => 4)
      expect(result["confidence"]).to be >= 0.8
    end

    it "is unknown with too little to compare, or before analysis has run" do
      expect(identity(1)).to eq("intro" => "unknown", "confidence" => 0.0, "compared" => 0)

      opening(1)
      opening(2)
      expect(identity(1)).to include("intro" => "unknown", "compared" => 1)

      # A show without a theme of its own: its episodes' openings disagree.
      show.episodes.each { |each| AudioFingerprint.where(media_file: each.editions.first.media_file).delete_all }
      (1..4).each { |number| opening(number, with_theme: false, intro: true) }
      opening(5)
      expect(identity(5)).to include("intro" => "unknown", "confidence" => 0.0)
    end

    it "is not from a kid profile, nor for another household's episode" do
      expect(identity(1, headers: auth_headers(admin).merge(profile_header(kid)))).to have_key("errors")
      expect(response).to have_http_status(:forbidden)

      identity(1, headers: auth_headers(create_user(household: create_household(name: "Other"), role: "admin")))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "files by content and by place" do
    it "finds files by fingerprint or exact path, and says what each is an edition of" do
      heat = film("Heat", tmdb_id: 949, imdb_id: "tt0113277")
      heat_file = heat.editions.first.media_file
      heat_file.update!(fingerprint: "fp-heat")
      heat.editions.first.update!(name: "Director's Cut")
      show = series("Severance", [ [ 1, 1, false ], [ 1, 2, false ] ], tmdb_id: 95_396)
      double = media_file(tv, "Severance/S01E01-E02.mkv", fingerprint: "fp-double")
      [ episode(show, 1, 1), episode(show, 1, 2) ].each { |each| each.editions.create!(media_file: double) }
      media_file(films, "Other.mkv", fingerprint: "fp-other")

      get "/api/v1/media_files", params: { fingerprint: "fp-heat, fp-double" }, headers: auth_headers(admin)
      rows = json.index_by { |row| row["fingerprint"] }
      expect(rows.keys).to contain_exactly("fp-heat", "fp-double")
      expect(rows["fp-heat"]["matches"]).to eq([ { "type" => "movie", "id" => heat.id, "tmdb_id" => 949, "imdb_id" => "tt0113277",
                                                   "edition" => "Director's Cut" } ])
      expect(rows["fp-double"]["matches"]).to contain_exactly(
        { "type" => "episode", "id" => episode(show, 1, 1).id, "show_id" => show.id, "show_tmdb_id" => 95_396,
          "season_number" => 1, "episode_number" => 1 },
        { "type" => "episode", "id" => episode(show, 1, 2).id, "show_id" => show.id, "show_tmdb_id" => 95_396,
          "season_number" => 1, "episode_number" => 2 }
      )

      get "/api/v1/media_files", params: { path: heat_file.path }, headers: auth_headers(admin)
      expect(json.map { |row| row["id"] }).to eq([ heat_file.id ])
      get "/api/v1/media_files", params: { path: heat_file.path.delete_suffix(".mkv") }, headers: auth_headers(admin)
      expect(json).to eq([])
      get "/api/v1/media_files", params: { fingerprint: "fp-nothing" }, headers: auth_headers(admin)
      expect(json).to eq([])
    end

    it "names no title a restricted profile couldn't open, and nothing to a kid" do
      heat = film("Heat", rating: "R", tmdb_id: 949)
      teen = Profile.create!(household: household, name: "Teen", max_rating_age: 13)

      get "/api/v1/media_files", params: { path: heat.editions.first.media_file.path }, headers: auth_headers(member).merge(profile_header(teen))
      expect(json.sole["matches"]).to eq([])
      get "/api/v1/media_files", params: { path: heat.editions.first.media_file.path }, headers: auth_headers(member)
      expect(json.sole["matches"].sole).to include("id" => heat.id)

      get "/api/v1/media_files", headers: auth_headers(admin).merge(profile_header(kid))
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "lists each library's kind and roots" do
    films
    tv
    get "/api/v1/libraries", headers: auth_headers(admin)
    expect(json.map { |row| row.slice("kind", "roots") }).to contain_exactly(
      { "kind" => "movies", "roots" => films.roots }, { "kind" => "shows", "roots" => tv.roots }
    )
  end
end
