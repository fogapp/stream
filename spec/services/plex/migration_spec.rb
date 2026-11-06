# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Plex::Migration do
  SERVER = "http://plex.lan:32400"

  let(:household) { Household.create!(name: "Plex") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root) }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:profile) { Profile.default_for(household) }
  let(:kids) { Profile.create!(household: household, name: "Kids") }
  let(:connection) { PlexConnection.create!(household: household, server_url: SERVER, token: "admintoken", machine_identifier: "abc") }
  let(:t1) { Time.zone.parse("2025-03-01 20:00") }
  let(:t2) { Time.zone.parse("2025-04-01 21:00") }

  let!(:heat) { Movie.create!(household: household, library: library, title: "Heat", year: 1995, tmdb_id: 949) }
  let!(:alien) { Movie.create!(household: household, library: library, title: "Alien", year: 1979) }
  let!(:primer) do
    Movie.create!(household: household, library: library, title: "Primer Proper", year: 2004).tap do |movie|
      file = MediaFile.create!(household: household, library: library, path: "#{root}/Primer.mkv", size: 12_345,
        mtime: Time.current, state: "probed")
      movie.editions.create!(media_file: file)
    end
  end
  let!(:severance) do
    Show.create!(household: household, library: tv, folder: "Severance", title: "Severance", tmdb_id: 95_396).tap do |show|
      season = show.seasons.create!(season_number: 1)
      [ 1, 2 ].each { |n| show.episodes.create!(season: season, season_number: 1, episode_number: n) }
    end
  end

  def plex(path, metadata_or_container, token: "admintoken", query: {})
    container = metadata_or_container.is_a?(Hash) ? metadata_or_container : { "Metadata" => metadata_or_container, "totalSize" => metadata_or_container.size }
    stub_request(:get, %r{\A#{Regexp.escape(SERVER + path)}(\?|\z)})
      .with(headers: { "X-Plex-Token" => token }, query: hash_including(query.transform_keys(&:to_s).transform_values(&:to_s)))
      .to_return(status: 200, body: { "MediaContainer" => container }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def movies_for(heat_views:, alien_offset_ms:)
    [
      { "ratingKey" => "10", "title" => "Heat", "year" => 1995, "Guid" => [ { "id" => "tmdb://949" }, { "id" => "imdb://tt0113277" } ],
        "viewCount" => heat_views, "lastViewedAt" => t1.to_i, "duration" => 10_200_000 },
      { "ratingKey" => "11", "title" => "Alien", "year" => 1979, "viewOffset" => alien_offset_ms, "lastViewedAt" => t2.to_i,
        "duration" => 7_020_000 },
      { "ratingKey" => "12", "title" => "Zardoz", "year" => 1974, "viewCount" => 1, "lastViewedAt" => t1.to_i },
      { "ratingKey" => "13", "title" => "Primer", "year" => 2004, "viewCount" => 1, "lastViewedAt" => t1.to_i,
        "Media" => [ { "Part" => [ { "file" => "/data/movies/Primer.mkv", "size" => 12_345 } ] } ] }
    ]
  end

  def stub_server(token: "admintoken", heat_views: 2, alien_offset_ms: 1_800_000, movies: nil, shows: nil)
    plex("/identity", { "machineIdentifier" => "abc", "friendlyName" => "Den" }, token: token)
    plex("/library/sections", { "Directory" => [ { "key" => "1", "type" => "movie" }, { "key" => "2", "type" => "show" } ] }, token: token)
    plex("/library/sections/1/all", movies || movies_for(heat_views: heat_views, alien_offset_ms: alien_offset_ms), token: token,
      query: { type: 1 })
    plex("/library/sections/2/all", shows || [ { "ratingKey" => "50", "title" => "Severance", "Guid" => [ { "id" => "tmdb://95396" } ] } ],
      token: token, query: { type: 2 })
    plex("/library/sections/1/collections", [], token: token)
    plex("/library/sections/2/collections", [], token: token)
    plex("/playlists", [], token: token, query: { playlistType: "video" })
    plex("/library/sections/2/all", [
      { "ratingKey" => "51", "grandparentRatingKey" => "50", "grandparentTitle" => "Severance", "parentIndex" => 1, "index" => 1,
        "viewCount" => 1, "lastViewedAt" => t1.to_i },
      { "ratingKey" => "52", "grandparentRatingKey" => "50", "grandparentTitle" => "Severance", "parentIndex" => 1, "index" => 2,
        "viewOffset" => 600_000, "lastViewedAt" => t2.to_i }
    ], token: token, query: { type: 4 })
  end

  def run(dry_run:)
    import = PlexImport.create!(household: household, dry_run: dry_run)
    described_class.new(import).call
    import.reload
  end

  before do
    connection.plex_user_mappings.create!(plex_user_id: "1", plex_name: "Alex", plex_admin: true, profile: profile)
    stub_server
  end

  it "matches by TMDB id, by the file itself, by title and year, and lists what it couldn't" do
    import = run(dry_run: true)

    expect(import.status).to eq("succeeded")
    expect(import.counts).to include("movies_in_plex" => 4, "movies_matched" => 3, "episodes_in_plex" => 2, "episodes_matched" => 2,
      "matched_by_tmdb_id" => 1, "matched_by_same_file" => 1, "matched_by_title_and_year" => 1)
    expect(import.unmatched).to eq([ { "kind" => "movie", "title" => "Zardoz (1974)" } ])
  end

  it "counts what it would import on a dry run and writes nothing" do
    import = run(dry_run: true)
    expect(import.counts).to include("watched_imported" => 3, "in_progress_imported" => 2)
    expect(WatchState.count).to eq(0)
  end

  it "imports watched, in-progress, play counts and dates" do
    run(dry_run: false)

    expect(WatchState.find_by(playable: heat)).to have_attributes(completed_at: t1, play_count: 2, position_seconds: 0)
    expect(WatchState.find_by(playable: alien)).to have_attributes(completed_at: nil, position_seconds: 1800.0, last_watched_at: t2,
      duration_seconds: 7020.0)
    expect(WatchState.find_by(playable: primer).completed_at).to eq(t1)
    episode2 = severance.episodes.find_by(episode_number: 2)
    expect(WatchState.find_by(playable: episode2).position_seconds).to eq(600.0)
    expect(connection.reload.last_synced_at).to be_present
  end

  it "changes nothing when run again, and never overwrites a newer view in Stream" do
    run(dry_run: false)
    WatchState.find_by(playable: heat).update!(last_watched_at: t2 + 1.day, completed_at: nil, position_seconds: 300)

    second = run(dry_run: false)

    expect(second.counts).to include("unchanged" => 4, "newer_in_stream" => 1)
    expect(second.counts).not_to have_key("watched_imported")
    expect(WatchState.find_by(playable: heat).position_seconds).to eq(300)
  end

  it "picks up what was watched in Plex since the last run" do
    run(dry_run: false)
    WebMock.reset!
    stub_server(alien_offset_ms: 0)
    plex("/library/sections/1/all", movies_for(heat_views: 3, alien_offset_ms: 0).map { |m| m["ratingKey"] == "10" ? m.merge("lastViewedAt" => (t2 + 2.days).to_i) : m },
      query: { type: 1 })

    run(dry_run: false)
    expect(WatchState.find_by(playable: heat)).to have_attributes(play_count: 3, completed_at: t2 + 2.days)
  end

  it "imports another home user's history with their own server token" do
    connection.plex_user_mappings.create!(plex_user_id: "2", plex_uuid: "kid-uuid", plex_name: "Kid", profile: kids)
    stub_request(:post, "https://plex.tv/api/v2/home/users/kid-uuid/switch").to_return(status: 200, body: { authToken: "kidaccount" }.to_json)
    stub_request(:get, "https://plex.tv/api/v2/resources?includeHttps=1").with(headers: { "X-Plex-Token" => "kidaccount" })
      .to_return(status: 200, body: [ { "clientIdentifier" => "abc", "accessToken" => "kidtoken" } ].to_json)
    stub_server(token: "kidtoken", heat_views: 0, alien_offset_ms: 0)

    import = run(dry_run: false)

    kid_row = import.users.find { |user| user["plex_name"] == "Kid" }
    expect(kid_row).to include("profile" => "Kids")
    expect(WatchState.where(profile: kids, playable: heat)).to be_empty
    expect(WatchState.where(profile: kids, playable: primer).sole.completed_at).to eq(t1)
  end

  describe "part 2: ratings, collections and what people changed" do
    it "imports each user's stars for movies, shows and episodes, the newer rating winning" do
      movies = movies_for(heat_views: 2, alien_offset_ms: 0).map { |m| m["ratingKey"] == "10" ? m.merge("userRating" => 8.0, "lastRatedAt" => t1.to_i) : m }
      stub_server(movies: movies, shows: [ { "ratingKey" => "50", "title" => "Severance", "Guid" => [ { "id" => "tmdb://95396" } ],
        "userRating" => 10.0, "lastRatedAt" => t2.to_i } ])

      import = run(dry_run: false)

      expect(import.counts).to include("ratings_imported" => 2)
      expect(Rating.find_by(profile: profile, rateable: heat)).to have_attributes(value: 8.0, rated_at: t1)
      expect(Rating.find_by(profile: profile, rateable: severance).value).to eq(10.0)

      Rating.find_by(rateable: heat).update!(value: 4.0, rated_at: t2)
      expect(run(dry_run: false).counts).to include("ratings_unchanged" => 2)
      expect(Rating.find_by(rateable: heat).value).to eq(4.0)
    end

    it "brings the title and summary someone locked in Plex, locked here too — unless changed here since" do
      heat.update!(tagline: "Mine", locked_fields: [ "tagline" ])
      movies = movies_for(heat_views: 2, alien_offset_ms: 0).map do |m|
        next m unless m["ratingKey"] == "10"

        m.merge("title" => "Heat (Director's Definitive Edition)", "summary" => "Our summary.", "tagline" => "Theirs",
          "Genre" => [ { "tag" => "Crime" } ],
          "Field" => [ { "name" => "title", "locked" => true }, { "name" => "summary", "locked" => true },
                       { "name" => "tagline", "locked" => true }, { "name" => "genre", "locked" => true } ])
      end
      stub_server(movies: movies)

      expect(run(dry_run: true).counts).to include("custom_fields_imported" => 3)
      expect(heat.reload.title).to eq("Heat")

      run(dry_run: false)
      expect(heat.reload).to have_attributes(title: "Heat (Director's Definitive Edition)", overview: "Our summary.", tagline: "Mine",
        genres: [ "Crime" ], locked_fields: %w[genres overview tagline title])
    end

    it "brings a poster chosen in Plex, and TMDB leaves it alone" do
      require_ffprobe!
      storage = Dir.mktmpdir("stream-storage")
      stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => storage))
      png = File.join(Dir.mktmpdir, "poster.png")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i color=c=0x3366cc:s=500x750 -frames:v 1 #{png}])
      stub_request(:get, "#{SERVER}/library/metadata/10/thumb/1700000000").to_return(status: 200, body: File.binread(png))
      movies = movies_for(heat_views: 2, alien_offset_ms: 0).map do |m|
        m["ratingKey"] == "10" ? m.merge("thumb" => "/library/metadata/10/thumb/1700000000", "Field" => [ { "name" => "thumb", "locked" => true } ]) : m
      end
      stub_server(movies: movies)

      run(dry_run: false)

      artwork = Artwork.find_by(owner: heat, kind: "poster")
      expect(artwork).to have_attributes(source: "plex", state: "ready")
      expect(heat.reload.locked_fields).to eq([ "poster_path" ])
      heat.update!(poster_path: "/tmdb.jpg")
      expect(Artworks::Sync.new(heat).wanted).not_to have_key(Artwork::Kind::Poster)
    ensure
      FileUtils.rm_rf(storage) if storage
    end

    it "makes the server's collections the household's own, smart ones as rules or as they stand, once" do
      stub_server
      plex("/library/sections/1/collections", [
        { "ratingKey" => "900", "title" => "Heist nights", "summary" => "Crews.", "smart" => "0" },
        { "ratingKey" => "901", "title" => "Unwatched crime", "smart" => "1",
          "content" => "/library/sections/1/all?type=1&genre=6&year%3E%3E=1990&unwatched=1&sort=titleSort" },
        { "ratingKey" => "902", "title" => "Directed by Mann", "smart" => "1", "content" => "/library/sections/1/all?type=1&director=77" }
      ])
      plex("/library/sections/1/genre", { "Directory" => [ { "key" => "6", "title" => "Crime" } ] })
      plex("/library/collections/900/children", [ { "ratingKey" => "10", "type" => "movie" }, { "ratingKey" => "12", "type" => "movie" },
                                                   { "ratingKey" => "11", "type" => "movie" } ])
      plex("/library/collections/902/children", [ { "ratingKey" => "10", "type" => "movie" } ])

      import = run(dry_run: false)

      expect(import.counts).to include("collections_in_plex" => 3, "smart_collections_imported" => 1, "smart_collections_snapshotted" => 1,
        "collections_imported" => 2)
      smart = Collection.find_by(plex_key: "901")
      expect(smart).to have_attributes(kind: "smart", title: "Unwatched crime")
      expect(smart.rules).to include("kinds" => %w[movie], "genres" => %w[Crime], "year_from" => 1990, "unwatched" => true, "sort" => "title")
      # Plex's director filter isn't one Stream's rules can say: what it lists today.
      expect(Collection.find_by(plex_key: "902")).to have_attributes(kind: "manual", title: "Directed by Mann")
      expect(Collection.find_by(plex_key: "902").items).to eq([ heat ])
      collection = Collection.find_by(plex_key: "900")
      expect(collection).to have_attributes(kind: "manual", title: "Heist nights", overview: "Crews.", plex_key: "900")
      expect(collection.items).to eq([ heat, alien ])

      collection.collection_items.create!(item: primer, position: 5)
      run(dry_run: false)
      expect(Collection.count).to eq(3)
      expect(collection.reload.items).to eq([ heat, alien, primer ])
    end
  end

  it "brings each user's playlists to their profile, in order, smart ones as they stand, once" do
    stub_server
    plex("/playlists", [ { "ratingKey" => "700", "title" => "Rainy Sunday", "smart" => "0" }, { "ratingKey" => "701", "title" => "Recent", "smart" => "1" } ],
      query: { playlistType: "video" })
    plex("/playlists/700/items", [ { "ratingKey" => "52" }, { "ratingKey" => "10" }, { "ratingKey" => "12" } ])
    plex("/playlists/701/items", [ { "ratingKey" => "11" } ])

    import = run(dry_run: false)

    expect(import.users.first).to include("playlists_imported" => 2, "playlist_items_imported" => 3, "smart_playlists_snapshotted" => 1)
    expect(Playlist.find_by(plex_key: "701").items).to eq([ alien ])
    playlist = Playlist.find_by(plex_key: "700")
    expect(playlist).to have_attributes(title: "Rainy Sunday", profile: profile, plex_key: "700")
    expect(playlist.items).to eq([ severance.episodes.find_by(episode_number: 2), heat ])

    run(dry_run: false)
    expect(Playlist.count).to eq(2)
    expect(PlaylistItem.count).to eq(3)
  end

  it "records a failure without leaving the import running" do
    WebMock.reset!
    stub_request(:get, %r{/identity}).to_return(status: 401)

    import = run(dry_run: true)
    expect(import).to have_attributes(status: "failed", error: include("rejected our credentials"))
  end
end
