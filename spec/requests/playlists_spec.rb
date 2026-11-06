# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Playlists", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }
  let(:kids) { Profile.create!(household: household, name: "Kids") }

  before { require_ffprobe! }

  def movie_with(title, fixture = "h264_aac.mp4")
    root = build_root("#{title}/#{title}.mp4" => fixture)
    library = create_library(household: household, roots: root, name: title)
    path = File.join(root, title, "#{title}.mp4")
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    Movie.create!(household: household, library: library, title: title, year: 2000).tap { |movie| movie.editions.create!(media_file: file) }
  end

  it "is made, filled and ordered by its profile, and plays through in order" do
    heat = movie_with("Heat")
    primer = movie_with("Primer")

    post "/api/v1/playlists", params: { title: "Rainy Sunday", item_type: "movie", item_id: heat.id }, headers: headers
    id = json["id"]
    post "/api/v1/playlists/#{id}/items", params: { item_type: "movie", item_id: primer.id }, headers: headers

    get "/api/v1/playlists", headers: headers
    expect(json.map { |row| row["title"] }).to eq([ "Watch later", "Rainy Sunday" ])
    expect(json.last).to include("item_count" => 2, "first" => { "kind" => "movie", "id" => heat.id })

    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: heat.id, playlist_id: id }, headers: headers
    expect(json["next_up"]).to include("kind" => "movie", "id" => primer.id, "title" => "Primer", "playlist_id" => id)

    put "/api/v1/playlists/#{id}/order", params: { ids: [ primer.id, heat.id ] }, headers: headers
    get "/api/v1/playlists/#{id}", headers: headers
    expect(json["items"].map { |item| item["title"] }).to eq(%w[Primer Heat])

    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: heat.id, playlist_id: id }, headers: headers
    expect(json["next_up"]).to be_nil
  end

  it "belongs to one profile" do
    Profile.default_for(household)
    playlist = Playlist.create!(household: household, profile: kids, title: "Cartoons")
    get "/api/v1/playlists/#{playlist.id}", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/api/v1/playlists", headers: headers.merge(profile_header(kids))
    expect(json.map { |row| row["title"] }).to eq([ "Watch later", "Cartoons" ])
  end
end
