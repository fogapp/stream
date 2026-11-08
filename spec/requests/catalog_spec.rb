# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Catalog", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }
  let(:profile) { Profile.default_for(household) }
  let(:movies) { create_library(household: household, roots: build_root, name: "Movies") }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def file_in(library, name, state: "probed")
    MediaFile.create!(household: household, library: library, path: File.join(library.roots.first, name), size: 1,
      mtime: Time.current, state: state, duration_seconds: 3600)
  end

  def movie(title, year: 2000, state: "probed")
    Movie.create!(household: household, library: movies, title: title, year: year).tap do |movie|
      movie.editions.create!(media_file: file_in(movies, "#{title}.mp4", state: state))
    end
  end

  def show_with(title, episodes)
    show = Show.create!(household: household, library: tv, folder: title, title: title)
    episodes.each do |season_number, number|
      season = show.seasons.find_or_create_by!(season_number: season_number)
      episode = show.episodes.create!(season: season, season_number: season_number, episode_number: number,
        title: "Episode #{number}")
      episode.editions.create!(media_file: file_in(tv, "#{title}/S#{season_number}E#{number}.mkv"))
    end
    show
  end

  def watched(playable) = Playback::Progress.mark(profile, playable, watched: true)

  describe "movies" do
    it "lists only movies with a readable file, with this profile's progress" do
      heat = movie("Heat")
      movie("Broken", state: "broken")
      alien = movie("Alien")
      watched(alien)
      WatchState.create!(profile: profile, playable: heat, position_seconds: 1800, duration_seconds: 3600)

      get "/api/v1/movies", params: { library_id: movies.id }, headers: headers

      expect(json.map { |card| [ card["title"], card["watched"], card["progress"] ] })
        .to eq([ [ "Alien", true, nil ], [ "Heat", false, 0.5 ] ])
    end

    it "filters to unwatched and searches titles ignoring accents" do
      movie("Amélie")
      watched(movie("Heat"))

      get "/api/v1/movies", params: { unwatched: true }, headers: headers
      expect(json.map { |card| card["title"] }).to eq([ "Amélie" ])

      get "/api/v1/movies", params: { q: "amelie" }, headers: headers
      expect(json.map { |card| card["title"] }).to eq([ "Amélie" ])
    end

    it "says where each letter starts in the A–Z grid, for its alphabet" do
      %w[Alien Amélie Heat 1917 The\ Thing Élite].each { |title| movie(title) }
      watched(Movie.find_by!(title: "Heat"))

      get "/api/v1/movies/letters", params: { library_id: movies.id }, headers: headers
      expect(json).to eq([ { "letter" => "#", "index" => 0 }, { "letter" => "A", "index" => 1 },
                           { "letter" => "E", "index" => 3 }, { "letter" => "H", "index" => 4 }, { "letter" => "T", "index" => 5 } ])
      get "/api/v1/movies", params: { library_id: movies.id }, headers: headers
      expect(json.map { |card| card["title"] }).to eq([ "1917", "Alien", "Amélie", "Élite", "Heat", "The Thing" ])

      get "/api/v1/movies/letters", params: { unwatched: true, q: "li" }, headers: headers
      expect(json.map { |start| start["letter"] }).to eq(%w[A E])
    end

    it "keeps the grid to a fixed number of queries however many movies there are" do
      3.times { |i| movie("M#{i}") }
      get "/api/v1/movies", headers: headers # first request makes the default profile
      small = count_queries { get "/api/v1/movies", headers: headers }.size
      6.times { |i| movie("N#{i}") }
      large = count_queries { get "/api/v1/movies", headers: headers }.size
      expect(large).to eq(small)
    end

    it "shows a movie page with its versions, cast and resume point" do
      heat = movie("Heat")
      person = Person.create!(tmdb_id: 1, name: "Al Pacino")
      heat.credits.create!(person: person, role: "cast", character: "Hanna")
      WatchState.create!(profile: profile, playable: heat, position_seconds: 600, duration_seconds: 3600)

      get "/api/v1/movies/#{heat.id}", headers: headers

      expect(json).to include("title" => "Heat", "resume_at" => 600.0)
      expect(json["cast"].sole).to include("name" => "Al Pacino", "character" => "Hanna", "role" => "cast")
      expect(json["versions"].sole).to include("filename" => "Heat.mp4", "playable" => false)
    end

    it "never shows another household's movies" do
      other = create_user(household: create_household(name: "Other"))
      heat = movie("Heat")
      get "/api/v1/movies/#{heat.id}", headers: auth_headers(other)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "shows" do
    it "picks the first episode for a new show, then the one after the furthest watched" do
      show = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ], [ 1, 3 ], [ 0, 1 ] ])

      get "/api/v1/shows/#{show.id}", headers: headers
      expect(json["next_up"]).to include("code" => "S01E01", "started_show" => false)
      expect(json["unwatched_count"]).to eq(4)
      expect(json["seasons"].map { |s| [ s["title"], s["available_count"] ] }).to eq([ [ "Specials", 1 ], [ "Season 1", 3 ] ])

      watched(show.episodes.find_by(season_number: 1, episode_number: 2))
      get "/api/v1/shows/#{show.id}", headers: headers
      expect(json["next_up"]).to include("code" => "S01E03", "started_show" => true)
    end

    it "prefers an episode in progress" do
      show = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ] ])
      watched(show.episodes.first)
      WatchState.create!(profile: profile, playable: show.episodes.last, position_seconds: 300, duration_seconds: 3600,
        last_watched_at: Time.current)

      get "/api/v1/shows/#{show.id}", headers: headers
      expect(json["next_up"]).to include("code" => "S01E02", "resume_at" => 300.0)
    end

    it "lists a season's episodes with availability and progress" do
      show = show_with("Severance", [ [ 1, 1 ] ])
      season = show.seasons.sole
      show.episodes.create!(season: season, season_number: 1, episode_number: 2, title: "Not downloaded")

      get "/api/v1/shows/#{show.id}/seasons/1", headers: headers

      expect(json["episodes"].map { |e| [ e["code"], e["available"] ] }).to eq([ [ "S01E01", true ], [ "S01E02", false ] ])
    end

    it "shows an admin the raw record behind a show — its folder, its files, and the show that looks like it" do
      admin = create_user(household: household, role: "admin")
      bluey = show_with("Bluey (2018)", [ [ 1, 1 ] ])
      bluey.update!(title: "Bluey", tmdb_id: 82728)
      stray = show_with("Bluey", [ [ 1, 1 ] ])
      stray.update!(tmdb_id: 82728)

      get "/api/v1/shows/#{bluey.id}/info", headers: headers
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/shows/#{bluey.id}/info", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(json).to include("folder" => "Bluey (2018)", "folder_paths" => [ File.join(tv.roots.first, "Bluey (2018)") ])
      expect(json["ids"]).to include("tmdb_id" => 82728)
      expect(json["counts"]).to include("episodes" => 1, "files" => 1, "missing_files" => 0)
      expect(json["files"].sole).to include("path" => File.join(tv.roots.first, "Bluey (2018)/S1E1.mkv"), "episode" => include("code" => "S01E01"))
      expect(json["directories"]).to eq([ { "path" => File.join(tv.roots.first, "Bluey (2018)"), "files" => 1 } ])
      expect(json["look_alikes"].sole).to include("id" => stray.id, "folder" => "Bluey", "tmdb_id" => 82728)

      get "/api/v1/shows/#{bluey.id}/seasons/1", headers: auth_headers(admin)
      expect(json["episodes"].sole["files"].sole).to include("path" => File.join(tv.roots.first, "Bluey (2018)/S1E1.mkv"), "state" => "probed")
      get "/api/v1/shows/#{bluey.id}/seasons/1", headers: headers
      expect(json["episodes"].sole).not_to have_key("files")
    end

    it "says where each letter starts among the shows with something unwatched" do
      show_with("Andor", [ [ 1, 1 ] ])
      watched(show_with("Barry", [ [ 1, 1 ] ]).episodes.first)
      show_with("Severance", [ [ 1, 1 ] ])

      get "/api/v1/shows/letters", params: { library_id: tv.id }, headers: headers
      expect(json).to eq([ { "letter" => "A", "index" => 0 }, { "letter" => "B", "index" => 1 }, { "letter" => "S", "index" => 2 } ])

      get "/api/v1/shows/letters", params: { library_id: tv.id, unwatched: true }, headers: headers
      expect(json).to eq([ { "letter" => "A", "index" => 0 }, { "letter" => "S", "index" => 1 } ])
    end

    it "filters to unwatched before paging, so every page is full" do
      watched(show_with("Andor", [ [ 1, 1 ] ]).episodes.first)
      watched(show_with("Barry", [ [ 1, 1 ] ]).episodes.first)
      show_with("Severance", [ [ 1, 1 ] ])
      show_with("Taskmaster", [ [ 1, 1 ] ])

      get "/api/v1/shows", params: { library_id: tv.id, unwatched: true, per: 2 }, headers: headers

      expect(json.map { |card| card["title"] }).to eq(%w[Severance Taskmaster])
      expect(response.headers["X-Total-Count"]).to eq("2")
    end

    it "marks a whole season watched" do
      show = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ], [ 2, 1 ] ])
      post "/api/v1/shows/#{show.id}/watched", params: { season_number: 1 }, headers: headers
      expect(WatchState.where.not(completed_at: nil).count).to eq(2)
    end
  end

  describe "home" do
    it "fills Continue watching, Next up and Recently added" do
      heat = movie("Heat")
      WatchState.create!(profile: profile, playable: heat, position_seconds: 900, duration_seconds: 3600, last_watched_at: 1.hour.ago)
      show = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ] ])
      watched(show.episodes.first)

      get "/api/v1/home", headers: headers

      hubs = json["hubs"].to_h { |hub| [ hub["title"], hub["items"] ] }
      expect(hubs.keys).to eq([ "Continue watching", "Next up", "Recently added in TV", "Recently added in Movies" ])
      expect(hubs["Continue watching"].map { |c| [ c["kind"], c["title"] ] }).to eq([ %w[movie Heat] ])
      expect(hubs["Next up"].map { |c| c["code"] }).to eq([ "S01E02" ])
      expect(hubs["Recently added in Movies"].map { |c| c["title"] }).to eq([ "Heat" ])
      expect(hubs["Recently added in TV"].map { |c| [ c["kind"], c.dig("show", "title"), c["code"], c["watched"] ] })
        .to eq([ [ "episode", "Severance", "S01E01", true ], [ "episode", "Severance", "S01E02", false ] ])
      # A few of each, once per title: Heat is also just added, Severance a new show.
      expect(json["heroes"].map { |hero| [ hero["title"], hero["label"] ] }).to eq([ [ "Heat", "Continue watching" ], %w[Severance Next\ up] ])
      expect(json["heroes"].first).to include("play" => { "kind" => "movie", "id" => heat.id }, "resume_at" => 900.0)
      expect(json["heroes"].second).to include("subtitle" => start_with("S01E02"), "play" => { "kind" => "episode", "id" => show.episodes.second.id })
      expect(json["heroes"]).to include(json["hero"])
    end

    it "picks the hero at random from its candidates" do
      movie("Heat")
      movie("Ronin")
      titles = Array.new(20) do
        get "/api/v1/home", headers: headers
        json.dig("hero", "title")
      end
      expect(titles.uniq).to contain_exactly("Heat", "Ronin")
    end

    it "lists each new episode in Recently added, and gives the hero a show's arrival as one" do
      show = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ], [ 2, 1 ], [ 2, 2 ], [ 2, 3 ] ])
      Edition.where(playable: show.episodes).update_all(created_at: 1.month.ago) # rubocop:disable Rails/SkipsModelValidations
      Edition.where(playable: show.episodes.where(season_number: 2)).update_all(created_at: 1.day.ago) # rubocop:disable Rails/SkipsModelValidations
      other = show_with("Andor", [ [ 1, 1 ], [ 1, 2 ], [ 1, 3 ] ])
      Edition.where(playable: other.episodes).update_all(created_at: 2.months.ago) # rubocop:disable Rails/SkipsModelValidations
      Edition.where(playable: other.episodes.where(episode_number: [ 2, 3 ])).update_all(created_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations

      get "/api/v1/home", headers: headers

      tv = json["hubs"].find { |hub| hub["title"] == "Recently added in TV" }
      expect(tv["kind"]).to eq("wide")
      # Newest first, a show's episodes together and in order.
      expect(tv["items"].map { |c| [ c.dig("show", "title"), c["code"] ] }.first(5)).to eq([
        %w[Severance S02E01], %w[Severance S02E02], %w[Severance S02E03], %w[Andor S01E02], %w[Andor S01E03]
      ])
      expect(json["heroes"].map { |hero| [ hero["title"], hero["label"] ] }).to eq([ [ "Severance", "Season 2 added" ], [ "Andor", "2 new episodes" ] ])
      expect(json["heroes"].first).to include("play" => { "kind" => "episode", "id" => show.episodes.find_by(season_number: 1, episode_number: 1).id })
    end

    it "fills Recently added from the shows with the newest arrivals, past a row's worth of shows" do
      shows = (1..(Viewing::Home::HUB_SIZE + 4)).map do |n|
        show_with("Show #{n}", [ [ 1, 1 ] ]).tap do |made|
          Edition.where(playable: made.episodes).update_all(created_at: n.hours.ago) # rubocop:disable Rails/SkipsModelValidations
        end
      end

      get "/api/v1/home", headers: headers

      items = json["hubs"].find { |hub| hub["title"] == "Recently added in TV" }["items"]
      expect(items.map { |c| c.dig("show", "title") }).to eq(shows.first(Viewing::Home::HUB_SIZE).map(&:title))
    end

    it "stands a batch of a show's episodes in Recently added as the show, the season it came in when there was one" do
      west_wing = show_with("The West Wing", (1..3).flat_map { |season| (1..6).map { |number| [ season, number ] } })
      Edition.where(playable: west_wing.episodes).update_all(created_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
      severance = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ], [ 2, 1 ], [ 2, 2 ], [ 2, 3 ], [ 2, 4 ] ])
      Edition.where(playable: severance.episodes).update_all(created_at: 1.month.ago) # rubocop:disable Rails/SkipsModelValidations
      Edition.where(playable: severance.episodes.where(season_number: 2)).update_all(created_at: 1.day.ago) # rubocop:disable Rails/SkipsModelValidations
      andor = show_with("Andor", [ [ 1, 1 ], [ 1, 2 ] ])
      Edition.where(playable: andor.episodes).update_all(created_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations

      get "/api/v1/home", headers: headers

      items = json["hubs"].find { |hub| hub["title"] == "Recently added in TV" }["items"]
      expect(items.map { |c| [ c["kind"], c.dig("show", "title") || c["title"], c["arrival"] || c["code"], c["season_number"] ] }).to eq([
        [ "show", "The West Wing", "New show", nil ],
        [ "show", "Severance", "Season 2 added", 2 ],
        [ "episode", "Andor", "S01E01", 1 ], [ "episode", "Andor", "S01E02", 1 ],
        [ "episode", "Severance", "S01E01", 1 ], [ "episode", "Severance", "S01E02", 1 ]
      ])
      expect(items.first).to include("id" => west_wing.id, "unwatched_count" => 18)
    end

    it "puts what's new from YouTube and in the TV libraries straight after Next up, and the rest after them" do
      movies
      tv
      channels = create_library(household: household, roots: build_root, kind: "channels", name: "YouTube")
      get "/api/v1/home", headers: headers

      expect(json["layout"].map { |hub| hub["key"] }).to eq([
        "continue_watching", "next_up", "recently_added:#{channels.id}", "recently_added:#{tv.id}", "subscriptions",
        "recently_added:#{movies.id}", "on_this_day"
      ])
    end

    it "keeps each profile's order of hubs, and the ones it hid" do
      heat = movie("Heat")
      WatchState.create!(profile: profile, playable: heat, position_seconds: 900, duration_seconds: 3600, last_watched_at: 1.hour.ago)
      library_key = "recently_added:#{movies.id}"

      patch "/api/v1/home", params: { order: [ library_key ], hidden: [ "next_up" ] }, headers: headers, as: :json

      expect(json["hubs"].map { |hub| hub["key"] }).to eq([ library_key, "continue_watching" ])
      expect(json["layout"].map { |hub| [ hub["key"], hub["hidden"] ] }).to eq([ [ library_key, false ], [ "continue_watching", false ], [ "next_up", true ], [ "subscriptions", false ], [ "on_this_day", false ] ])
      expect(profile.reload.home_layout).to eq("order" => [ library_key ], "hidden" => [ "next_up" ])
    end

    it "drops a dismissed card" do
      heat = movie("Heat")
      WatchState.create!(profile: profile, playable: heat, position_seconds: 900, duration_seconds: 3600, last_watched_at: 1.hour.ago)

      post "/api/v1/watch_states/hide", params: { playable_type: "movie", playable_id: heat.id }, headers: headers
      get "/api/v1/home", headers: headers
      expect(json["hubs"].map { |hub| hub["key"] }).not_to include("continue_watching")
    end

    it "orders Next up by the show watched most recently" do
      older = show_with("Andor", [ [ 1, 1 ], [ 1, 2 ] ])
      newer = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ] ])
      watched(newer.episodes.first)
      watched(older.episodes.first)
      WatchState.find_by!(playable: older.episodes.first).update!(last_watched_at: 1.day.ago)
      WatchState.find_by!(playable: newer.episodes.first).update!(last_watched_at: 1.hour.ago)

      get "/api/v1/home", headers: headers

      next_up = json["hubs"].find { |hub| hub["title"] == "Next up" }
      expect(next_up["items"].map { |card| card.dig("show", "title") }).to eq(%w[Severance Andor])
    end

    it "drops a show dismissed from Next up until another episode is watched" do
      show = show_with("Severance", [ [ 1, 1 ], [ 1, 2 ], [ 1, 3 ] ])
      watched(show.episodes.first)
      next_up = show.episodes.find_by(episode_number: 2)

      post "/api/v1/watch_states/hide", params: { playable_type: "episode", playable_id: next_up.id }, headers: headers
      get "/api/v1/home", headers: headers
      expect(json["hubs"].map { |hub| hub["key"] }).not_to include("next_up")

      Playback::Progress.mark(profile, next_up, watched: true)
      get "/api/v1/home", headers: headers
      expect(json["hubs"].find { |hub| hub["key"] == "next_up" }["items"].map { |c| c["code"] }).to eq([ "S01E03" ])
    end
  end

  describe "search" do
    it "finds what was said, each title once at its best line, best first, highlighted" do
      said = lambda do |title, lines|
        file = movie(title).editions.first.media_file
        transcript = Transcript.create!(media_file: file, source: "subtitles")
        lines.each_with_index do |text, index|
          TranscriptLine.create!(transcript: transcript, media_file: file, start_seconds: index * 10.0, end_seconds: index * 10.0 + 5, text: text)
        end
      end
      said.call("Jaws", [ "Nice day for a swim", "You're gonna need a bigger boat", "A bigger boat, a bigger boat" ])
      said.call("Titanic", [ "It's a big boat" ])

      get "/api/v1/search", params: { q: "bigger boat" }, headers: headers

      expect(json["said"].map { |hit| [ hit["title"], hit["start"] ] }).to eq([ [ "Jaws", 20 ] ])
      expect(json["said"].sole["snippet"]).to include("<<bigger>> <<boat>>")
    end

    it "finds titles, episodes and people, forgiving accents and typos" do
      movie("Amélie", year: 2001)
      heat = movie("Heat", year: 1995)
      movie("Hidden", state: "broken")
      show = show_with("Severance", [ [ 1, 1 ] ])
      show.episodes.first.update!(title: "Good News About Hell")
      pacino = Person.create!(name: "Al Pacino", tmdb_id: 1158)
      heat.credits.create!(person: pacino, role: "cast", character: "Vincent Hanna")
      Person.create!(name: "Al Unseen", tmdb_id: 9)

      get "/api/v1/search", params: { q: "amelie" }, headers: headers
      expect(json["movies"].map { |c| c["title"] }).to eq([ "Amélie" ])

      get "/api/v1/search", params: { q: "severence" }, headers: headers
      expect(json["shows"].map { |c| c["title"] }).to eq([ "Severance" ])

      get "/api/v1/search", params: { q: "hell" }, headers: headers
      expect(json["episodes"].map { |c| [ c["code"], c.dig("show", "title") ] }).to eq([ [ "S01E01", "Severance" ] ])

      get "/api/v1/search", params: { q: "pacino" }, headers: headers
      expect(json["people"].map { |p| p["name"] }).to eq([ "Al Pacino" ])

      get "/api/v1/search", params: { q: "hidden" }, headers: headers
      expect(json["movies"]).to eq([])
    end

    it "shows a person's titles in this household, with their part" do
      heat = movie("Heat", year: 1995)
      pacino = Person.create!(name: "Al Pacino", tmdb_id: 1158)
      heat.credits.create!(person: pacino, role: "cast", character: "Vincent Hanna")
      elsewhere = create_household
      Movie.create!(household: elsewhere, library: create_library(household: elsewhere, roots: build_root), title: "Other")
        .credits.create!(person: pacino, role: "cast")

      get "/api/v1/people/#{pacino.id}", headers: headers

      expect(json).to include("name" => "Al Pacino", "shows" => [])
      expect(json["movies"].map { |c| [ c["title"], c["credit"] ] }).to eq([ [ "Heat", "as Vincent Hanna" ] ])
    end
  end
end
