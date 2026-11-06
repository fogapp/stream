# typed: false
# frozen_string_literal: true

require "rails_helper"

# Small viewing pieces (PROPOSAL §7.1–7.3): rating an episode, choosing an
# episode's version, frame-stepping at the file's rate, and pinning a
# collection or playlist to Home.
RSpec.describe "Viewing gaps", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let!(:profile) { Profile.default_for(household) }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:show) { Show.create!(household: household, library: tv, folder: "Severance", title: "Severance") }
  let(:episode) do
    season = show.seasons.find_or_create_by!(season_number: 1)
    show.episodes.create!(season: season, season_number: 1, episode_number: 1, title: "Good News").tap do |episode|
      %w[hd uhd].each do |name|
        file = MediaFile.create!(household: household, library: tv, path: "/tv/#{name}.mkv", size: 1, mtime: Time.current, state: "probed")
        file.media_streams.create!(index: 0, kind: "video", codec: "hevc", height: name == "hd" ? 1080 : 2160, frame_rate: 23.976)
        episode.editions.create!(media_file: file, name: name.upcase)
      end
    end
  end

  it "rates an episode and lists its versions in the season" do
    put "/api/v1/rating", params: { rateable_type: "episode", rateable_id: episode.id, value: 8 }, headers: auth_headers(user)
    get "/api/v1/shows/#{show.id}/seasons/1", headers: auth_headers(user)
    row = json["episodes"].sole
    expect(row["my_rating"]).to eq(8)
    expect(row["versions"].map { |version| version["edition"] }).to contain_exactly("HD", "UHD")
  end

  it "pins a collection and a playlist to Home as rows, and unpins them" do
    movies = create_library(household: household, roots: build_root, name: "Films")
    heat = Movie.create!(household: household, library: movies, title: "Heat")
    heat.editions.create!(media_file: MediaFile.create!(household: household, library: movies, path: "/m/heat.mkv", size: 1,
      mtime: Time.current, state: "probed"))
    collection = Collection.create!(household: household, title: "Michael Mann", kind: "manual")
    collection.collection_items.create!(item: heat, position: 1)
    playlist = Playlist.create!(household: household, profile: profile, title: "Rainy Sunday")
    playlist.playlist_items.create!(item: episode, position: 1)

    post "/api/v1/home/pin", params: { kind: "collection", id: collection.id }, headers: auth_headers(user)
    post "/api/v1/home/pin", params: { kind: "playlist", id: playlist.id }, headers: auth_headers(user)
    get "/api/v1/home", headers: auth_headers(user)
    pinned = json["hubs"].select { |hub| hub["key"].start_with?("pinned_") }
    expect(pinned.map { |hub| [ hub["title"], hub["items"].map { |item| item["id"] } ] })
      .to eq([ [ "Michael Mann", [ heat.id ] ], [ "Rainy Sunday", [ episode.id ] ] ])
    get "/api/v1/collections/#{collection.id}", headers: auth_headers(user)
    expect(json["pinned_to_home"]).to be(true)

    delete "/api/v1/home/pin", params: { kind: "collection", id: collection.id }, headers: auth_headers(user)
    get "/api/v1/home", headers: auth_headers(user)
    expect(json["hubs"].map { |hub| hub["title"] }).not_to include("Michael Mann")

    other = Profile.create!(household: household, name: "Other")
    post "/api/v1/home/pin", params: { kind: "playlist", id: playlist.id }, headers: auth_headers(user).merge(profile_header(other))
    expect(response).to have_http_status(:not_found)
  end

  it "tells the player the file's frame rate, and an episode's show and season" do
    file = episode.media_files.first
    session = PlaybackSession.create!(household: household, profile: profile, playable: episode, media_file: file, method: "direct",
      decision: {}, started_at: Time.current, last_seen_at: Time.current)
    json = PlaybackSessionSerializer.session_json(session, token: "t", resume_at: 0.0)
    expect(json[:frame_rate]).to eq(23.976)
    expect(json).to include(show_id: episode.show_id, season_number: episode.season_number)
  end

  it "places home videos on a map, a kilometre at a time" do
    home = create_library(household: household, roots: build_root, kind: "home_videos", name: "Home videos")
    clip = lambda do |title, latitude, longitude, city|
      Clip.create!(household: household, library: home, title: title, sort_title: title, captured_at: Time.current, captured_source: "immich",
        latitude: latitude, longitude: longitude, city: city).tap do |made|
        made.editions.create!(media_file: MediaFile.create!(household: household, library: home, path: "/h/#{title}.mp4", size: 1,
          mtime: Time.current, state: "probed"))
      end
    end
    clip.call("beach", 50.8201, -0.1403, "Brighton")
    clip.call("pier", 50.8190, -0.1370, "Brighton")
    clip.call("hill", 51.5076, -0.1278, "London")
    clip.call("nowhere", nil, nil, nil)

    get "/api/v1/clips/places", params: { library_id: home.id }, headers: auth_headers(user)
    expect(json.map { |place| [ place["city"], place["count"] ] }).to eq([ [ "Brighton", 2 ], [ "London", 1 ] ])
    expect(json.first).to include("latitude" => 50.82, "longitude" => -0.14)
    expect(json.first["clips"].map { |card| card["title"] }).to contain_exactly("beach", "pier")
  end
end
