# typed: false
# frozen_string_literal: true

require "rails_helper"

# Choosing a poster or background by hand (PROPOSAL §7.2): one of TMDB's
# others, or an upload — rendered like any artwork and locked so a refresh
# never undoes it; resetting unlocks it.
RSpec.describe "Artwork choices", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:movie) { Movie.create!(household: household, library: library, title: "Heat", tmdb_id: 949, poster_path: "/first.jpg") }

  let(:png) do
    path = File.join(@storage, "poster.png")
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i color=c=0x3366cc:s=500x750 -frames:v 1 #{path}])
    path
  end

  before do
    require_ffprobe!
    @storage = Dir.mktmpdir("stream-storage")
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => @storage))
    TmdbSetting.create!(household: household, api_key: "k")
  end

  after { FileUtils.rm_rf(@storage) }

  def params_for(kind = "poster") = { owner_type: "movie", owner_id: movie.id, kind: kind }

  it "lists TMDB's other pictures, and keeps members out" do
    stub_request(:get, %r{api.themoviedb.org/3/movie/949/images}).to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { posters: [ { file_path: "/second.jpg", width: 1000, height: 1500, iso_639_1: "en", vote_count: 12 } ], backdrops: [] }.to_json)

    get "/api/v1/artwork_choices", params: params_for, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)

    get "/api/v1/artwork_choices", params: params_for, headers: auth_headers(admin)
    expect(json).to include("locked" => false, "current" => nil)
    expect(json["choices"].sole).to include("path" => "/second.jpg", "preview" => "https://image.tmdb.org/t/p/w342/second.jpg")
  end

  it "uses the one chosen, and a metadata refresh leaves it alone" do
    stub_request(:get, "https://image.tmdb.org/t/p/w780/second.jpg").to_return(status: 200, body: File.binread(png))
    put "/api/v1/artwork_choices/choose", params: params_for.merge(path: "/second.jpg"), headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)

    artwork = Artwork.find_by(owner: movie, kind: "poster")
    expect(artwork).to have_attributes(state: "ready", source: "tmdb", source_ref: "/second.jpg", width: 500)
    expect(movie.reload).to have_attributes(poster_path: "/second.jpg", locked_fields: include("poster_path"))
    expect(Artworks::Sync.new(movie).wanted).not_to have_key(Artwork::Kind::Poster)

    Catalog::Metadata.apply_movie(movie, { "id" => 949, "title" => "Heat", "poster_path" => "/first.jpg" })
    expect(movie.reload.poster_path).to eq("/second.jpg")
  end

  it "takes an uploaded picture, and refuses what isn't one" do
    post "/api/v1/artwork_choices/upload", params: params_for("backdrop").merge(file: Rack::Test::UploadedFile.new(png, "image/png")),
      headers: auth_headers(admin)
    expect(response).to have_http_status(:created)
    expect(Artwork.find_by(owner: movie, kind: "backdrop")).to have_attributes(state: "ready", source: "upload")
    expect(movie.reload.locked_fields).to include("backdrop_path")

    text = File.join(@storage, "notes.txt")
    File.write(text, "not a picture")
    post "/api/v1/artwork_choices/upload", params: params_for.merge(file: Rack::Test::UploadedFile.new(text, "image/png")),
      headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].sole).to include("isn't a picture")
  end

  it "goes back to TMDB's choice on reset" do
    movie.update!(locked_fields: %w[poster_path])
    expect do
      delete "/api/v1/artwork_choices/reset", params: params_for, headers: auth_headers(admin)
    end.to have_enqueued_job(RefreshMetadataJob).with("Movie", movie.id)
    expect(movie.reload.locked_fields).to eq([])
  end
end
