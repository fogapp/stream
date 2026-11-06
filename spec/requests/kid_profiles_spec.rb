# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Kid profiles", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let!(:everyone) { Profile.default_for(household) }
  let(:movies) { create_library(household: household, roots: build_root, name: "Movies") }
  let(:kids_movies) { create_library(household: household, roots: build_root, name: "Kids movies") }

  def movie(title, rating, library: movies)
    Movie.create!(household: household, library: library, title: title, year: 2000, content_rating: rating).tap do |movie|
      file = MediaFile.create!(household: household, library: library, path: "/m/#{title}.mkv", size: 1, mtime: Time.current, state: "probed")
      movie.editions.create!(media_file: file)
    end
  end

  def titles_for(profile)
    get "/api/v1/movies", headers: auth_headers(admin).merge(profile_header(profile))
    json.map { |row| row["title"] }.sort
  end

  it "keeps a kid under their rating ceiling, unrated titles out unless allowed, and a tagged title in" do
    movie("Paddington", "PG")
    movie("Heat", "R")
    movie("Home Movie", nil)
    alien = movie("Alien", "R")
    kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 10)

    expect(titles_for(kid)).to eq(%w[Paddington])
    kid.update!(allow_unrated: true)
    expect(titles_for(kid)).to eq([ "Home Movie", "Paddington" ])
    ProfileTag.create!(profile: kid, taggable: alien)
    expect(titles_for(kid)).to eq([ "Alien", "Home Movie", "Paddington" ])
    expect(titles_for(everyone).size).to eq(4)

    heat = Movie.find_by(title: "Heat")
    get "/api/v1/movies/#{heat.id}", headers: auth_headers(admin).merge(profile_header(kid))
    expect(response).to have_http_status(:not_found)
    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: heat.id }, headers: auth_headers(admin).merge(profile_header(kid))
    expect(response).to have_http_status(:not_found)
    get "/api/v1/search", params: { q: "heat" }, headers: auth_headers(admin).merge(profile_header(kid))
    expect(json["movies"]).to eq([])
  end

  it "keeps a title past the ceiling out of every write and every playlist" do
    heat = movie("Heat", "R")
    paddington = movie("Paddington", "PG")
    kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 10)
    as_kid = auth_headers(admin).merge(profile_header(kid))

    put "/api/v1/rating", params: { rateable_type: "movie", rateable_id: heat.id, value: 5 }, headers: as_kid
    expect(response).to have_http_status(:not_found)
    post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: heat.id, watched: true }, headers: as_kid
    expect(response).to have_http_status(:not_found)
    post "/api/v1/watch_later", params: { item_type: "movie", item_id: heat.id }, headers: as_kid
    expect(response).to have_http_status(:not_found)

    playlist = Playlist.watch_later_for(kid)
    post "/api/v1/playlists/#{playlist.id}/items", params: { item_type: "movie", item_id: heat.id }, headers: as_kid
    expect(response).to have_http_status(:not_found)

    # Put there before the ceiling, or by another way in: still not shown.
    PlaylistItem.create!(playlist: playlist, item: heat, position: 1)
    PlaylistItem.create!(playlist: playlist, item: paddington, position: 2)
    get "/api/v1/playlists/#{playlist.id}", headers: as_kid
    expect(json["items"].map { |item| item["title"] }).to eq(%w[Paddington])
  end

  it "shows a curated profile only what's tagged for it, from its libraries" do
    paddington = movie("Paddington", "PG", library: kids_movies)
    movie("Toy Story", "G", library: kids_movies)
    tagged_elsewhere = movie("Wall-E", "G")
    curated = Profile.create!(household: household, name: "Little", curated: true, library_ids: [ kids_movies.id ])
    ProfileTag.create!(profile: curated, taggable: paddington)
    ProfileTag.create!(profile: curated, taggable: tagged_elsewhere)

    expect(titles_for(curated)).to eq(%w[Paddington])
  end

  it "keeps a kid profile out of settings, even in an admin's browser, and out of changing its own limits" do
    kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
    get "/api/v1/youtube", headers: auth_headers(admin).merge(profile_header(kid))
    expect(response).to have_http_status(:forbidden)

    member = create_user(household: household)
    patch "/api/v1/profiles/#{kid.id}", params: { name: "Kiddo", max_rating_age: 16 }, headers: auth_headers(member).merge(profile_header(kid))
    expect(kid.reload).to have_attributes(name: "Kiddo", max_rating_age: 7)
  end

  it "gives a profile its own Up next countdown, skips and Still watching?" do
    root = build_root("Heat/Heat.mp4" => "h264_aac.mp4")
    require_ffprobe!
    path = File.join(root, "Heat/Heat.mp4")
    file = MediaFile.create!(household: household, library: create_library(household: household, roots: root), path: path, size: File.size(path),
      mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    heat = Movie.create!(household: household, library: file.library, title: "Heat", year: 1995).tap { |m| m.editions.create!(media_file: file) }
    kid = Profile.create!(household: household, name: "Kid", up_next_seconds: 0, always_skip_intro: true, still_watching_after: 0)

    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: heat.id }, headers: auth_headers(admin).merge(profile_header(kid))
    expect(json).to include("up_next_seconds" => 0, "still_watching_after" => 0)
    expect(json["skip"]).to include("intro" => true, "credits" => false)
  end
end
