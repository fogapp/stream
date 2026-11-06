# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Collections", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:viewer) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root, name: "Movies") }

  def movie(title, year:, tmdb_id: nil, collection: nil)
    Movie.create!(household: household, library: library, title: title, year: year, tmdb_id: tmdb_id,
      tmdb_collection_id: collection&.first, tmdb_collection_name: collection&.last).tap do |movie|
      file = MediaFile.create!(household: household, library: library, path: "/m/#{title}.mkv", size: 1, mtime: Time.current, state: "probed")
      movie.editions.create!(media_file: file)
    end
  end

  describe "from TMDB" do
    before { configure_tmdb(household) }

    it "gathers the films that name a collection, in TMDB's order, with its overview" do
      alien = movie("Alien", year: 1979, tmdb_id: 348)
      aliens = movie("Aliens", year: 1986, tmdb_id: 679)
      stub_tmdb("/collection/8091", { "id" => 8091, "name" => "Alien Collection", "overview" => "In space…",
        "poster_path" => "/c.jpg", "backdrop_path" => "/cb.jpg",
        "parts" => [ { "id" => 679, "release_date" => "1986-07-18" }, { "id" => 348, "release_date" => "1979-05-25" } ] })

      perform_enqueued_jobs(only: SyncCollectionJob) do
        Catalog::Metadata.apply_movie(aliens, tmdb_movie(id: 679, title: "Aliens", date: "1986-07-18",
          "belongs_to_collection" => { "id" => 8091, "name" => "Alien Collection" }))
        Catalog::Metadata.apply_movie(alien, tmdb_movie(id: 348, title: "Alien", date: "1979-05-25",
          "belongs_to_collection" => { "id" => 8091, "name" => "Alien Collection" }))
      end

      collection = Collection.sole
      expect(collection).to have_attributes(kind: "tmdb", title: "Alien Collection", overview: "In space…", poster_path: "/c.jpg")

      get "/api/v1/collections/#{collection.id}", headers: auth_headers(viewer)
      expect(json["items"].map { |item| item["title"] }).to eq(%w[Alien Aliens])

      get "/api/v1/movies/#{alien.id}", headers: auth_headers(viewer)
      expect(json["collections"]).to eq([ { "id" => collection.id, "title" => "Alien Collection", "kind" => "tmdb" } ])
    end

    it "lists the series' films no library has, in order, and lets go of one TMDB drops" do
      collection = Collection.create!(household: household, kind: "tmdb", tmdb_id: 8091, title: "Alien Collection")
      alien = movie("Alien", year: 1979, tmdb_id: 348)
      CollectionItem.create!(collection: collection, item: alien)
      parts = [
        { "id" => 8077, "title" => "Alien³", "release_date" => "1992-05-22", "overview" => "Ripley crash-lands.", "poster_path" => "/a3.jpg" },
        { "id" => 348, "title" => "Alien", "release_date" => "1979-05-25", "poster_path" => "/a.jpg" },
        { "id" => 679, "title" => "Aliens", "release_date" => "1986-07-18", "poster_path" => "/a2.jpg" },
        { "id" => 999_001, "title" => "Alien: Next", "release_date" => "" }
      ]
      expect { Catalog::Collections.apply(collection, { "name" => "Alien Collection", "parts" => parts }) }
        .to have_enqueued_job(SyncArtworkJob).exactly(4).times

      get "/api/v1/collections/#{collection.id}", headers: auth_headers(viewer)
      expect(json["items"].map { |item| item["title"] }).to eq(%w[Alien])
      expect(json["missing"].map { |part| [ part["title"], part["year"] ] }).to eq([ [ "Aliens", 1986 ], [ "Alien³", 1992 ], [ "Alien: Next", nil ] ])
      expect(json["missing"].second).to include("tmdb_id" => 8077, "overview" => "Ripley crash-lands.", "release_date" => "1992-05-22")

      Catalog::Collections.apply(collection, { "name" => "Alien Collection", "parts" => parts.first(3) })
      get "/api/v1/collections/#{collection.id}", headers: auth_headers(viewer)
      expect(json["missing"].map { |part| part["title"] }).to eq([ "Aliens", "Alien³" ])
      expect(CollectionPart.count).to eq(3)
    end

    it "doesn't list films nobody has to a profile with a rating ceiling" do
      collection = Collection.create!(household: household, kind: "tmdb", tmdb_id: 8091, title: "Alien Collection")
      CollectionItem.create!(collection: collection, item: movie("Alien", year: 1979, tmdb_id: 348))
      Catalog::Collections.apply(collection, { "name" => "Alien Collection",
                                               "parts" => [ { "id" => 679, "title" => "Aliens", "release_date" => "1986-07-18" } ] })

      get "/api/v1/collections/#{collection.id}", headers: auth_headers(viewer)
      expect(json["missing"].map { |part| part["title"] }).to eq([ "Aliens" ])
      kid = Profile.create!(household: household, name: "Kid", position: 1, max_rating_age: 13, allow_unrated: true)
      get "/api/v1/collections/#{collection.id}", headers: auth_headers(viewer).merge(profile_header(kid))
      expect(json["missing"]).to eq([])
    end

    it "keeps an admin's new name through the next refresh, and won't delete it" do
      collection = Collection.create!(household: household, kind: "tmdb", tmdb_id: 1, title: "Alien Collection")
      patch "/api/v1/collections/#{collection.id}", params: { title: "The Alien films" }, headers: auth_headers(admin)
      expect(collection.reload.locked_fields).to eq([ "title" ])

      Catalog::Collections.apply(collection, { "name" => "Alien Collection", "overview" => "New", "parts" => [] })
      expect(collection.reload).to have_attributes(title: "The Alien films", overview: "New")

      delete "/api/v1/collections/#{collection.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "by hand" do
    it "is made, filled, ordered and emptied by an admin, and browsed by anyone" do
      heat = movie("Heat", year: 1995)
      primer = movie("Primer", year: 2004)

      post "/api/v1/collections", params: { title: "Friday nights", item_type: "movie", item_id: heat.id }, headers: auth_headers(admin)
      expect(response).to have_http_status(:created)
      id = json["id"]
      post "/api/v1/collections/#{id}/items", params: { item_type: "movie", item_id: primer.id }, headers: auth_headers(admin)
      put "/api/v1/collections/#{id}/order", params: { ids: [ primer.id, heat.id ] }, headers: auth_headers(admin)

      get "/api/v1/collections", headers: auth_headers(viewer)
      expect(json.sole).to include("title" => "Friday nights", "collection_kind" => "manual", "item_count" => 2)
      get "/api/v1/collections/#{id}", headers: auth_headers(viewer)
      expect(json["items"].map { |item| item["title"] }).to eq(%w[Primer Heat])

      delete "/api/v1/collections/#{id}/items", params: { item_type: "movie", item_id: primer.id }, headers: auth_headers(admin)
      get "/api/v1/collections/#{id}", headers: auth_headers(viewer)
      expect(json["items"].map { |item| item["title"] }).to eq(%w[Heat])

      get "/api/v1/search", params: { q: "friday" }, headers: auth_headers(viewer)
      expect(json["collections"].map { |c| c["title"] }).to eq([ "Friday nights" ])

      delete "/api/v1/collections/#{id}", headers: auth_headers(admin)
      expect(Collection.count).to eq(0)
    end

    it "is only changed by an admin" do
      post "/api/v1/collections", params: { title: "Mine" }, headers: auth_headers(viewer)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "belonging to a library" do
    let(:kids) { create_library(household: household, roots: build_root, name: "Kids") }

    it "lists a library's own collections and the household's that hold something from it" do
      films = Movie.create!(household: household, library: kids, title: "Paddington").tap do |movie|
        movie.editions.create!(media_file: MediaFile.create!(household: household, library: kids, path: "/k/p.mkv", size: 1,
          mtime: Time.current, state: "probed"))
      end
      own = Collection.create!(household: household, title: "Bears", kind: "manual", library: kids)
      own.collection_items.create!(item: films, position: 1)
      shared = Collection.create!(household: household, title: "Family night", kind: "manual")
      shared.collection_items.create!(item: films, position: 1)
      Collection.create!(household: household, title: "Elsewhere", kind: "manual")

      get "/api/v1/collections", params: { library_id: kids.id }, headers: auth_headers(admin)
      expect(json.map { |card| card["title"] }).to contain_exactly("Bears", "Family night")
      expect(json.find { |card| card["title"] == "Bears" }["library"]).to include("name" => "Kids")

      patch "/api/v1/collections/#{shared.id}", params: { library_id: kids.id }, headers: auth_headers(admin)
      expect(shared.reload.library).to eq(kids)
      patch "/api/v1/collections/#{shared.id}", params: { library_id: "" }, headers: auth_headers(admin)
      expect(shared.reload.library).to be_nil
    end
  end
end
