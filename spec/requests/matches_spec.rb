# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TMDB settings and Needs match", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root) }

  describe "TMDB settings" do
    it "stores the key encrypted, never serializes it, and rematches on the first key" do
      patch "/api/v1/tmdb_setting", params: { tmdb_setting: { api_key: "secret-key" } }, headers: auth_headers(admin), as: :json

      expect(json).to include("configured" => true)
      expect(response.body).not_to include("secret-key")
      raw = ActiveRecord::Base.connection.select_value("SELECT api_key FROM tmdb_settings")
      expect(raw).not_to include("secret-key")
      expect(enqueued_jobs.map { |job| job["job_class"] }).to include("RematchLibrariesJob")
    end

    it "tests the connection and records the result" do
      configure_tmdb(household)
      stub_tmdb("/configuration", { "images" => {} })
      post "/api/v1/tmdb_setting/test", headers: auth_headers(admin)
      expect(json).to eq("ok" => true, "message" => "Connected to TMDB.")

      stub_request(:get, %r{/configuration}).to_return(status: 401, body: { status_message: "Invalid API key" }.to_json)
      post "/api/v1/tmdb_setting/test", headers: auth_headers(admin)
      expect(json["ok"]).to be(false)
      expect(TmdbSetting.sole.last_test_ok).to be(false)
    end

    it "is an admin's to change" do
      patch "/api/v1/tmdb_setting", params: { tmdb_setting: { api_key: "x" } }, headers: auth_headers(member), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "Needs match" do
    let!(:movie) do
      Movie.create!(household: household, library: library, title: "Dune", match_state: "needs_review",
        match_candidates: [ { "tmdb_id" => 438_631, "title" => "Dune", "year" => 2021 } ],
        match_reasons: { "summary" => "Dune (2021) and Dune (1984) fit equally well." })
    end

    before { configure_tmdb(household) }

    it "lists titles waiting on a person, with their candidates" do
      Movie.create!(household: household, library: library, title: "Heat", match_state: "matched", tmdb_id: 949)

      get "/api/v1/matches", headers: auth_headers(member)

      expect(json.map { |row| row["title"] }).to eq([ "Dune" ])
      expect(json.first).to include("kind" => "movie", "match_summary" => include("equally well"))
    end

    it "searches with the matcher's scoring and applies a pick" do
      stub_tmdb("/search/movie", { "results" => [ tmdb_movie(id: 841, title: "Dune", date: "1984-12-14") ] }, query: { query: "Dune", year: 1984 })
      post "/api/v1/matches/movie/#{movie.id}/search", params: { query: "Dune", year: 1984 }, headers: auth_headers(admin)
      expect(json.first).to include("tmdb_id" => 841, "year" => 1984, "reasons" => include("year matches"))

      stub_tmdb("/movie/841", tmdb_movie(id: 841, title: "Dune", date: "1984-12-14"))
      post "/api/v1/matches/movie/#{movie.id}", params: { tmdb_id: 841 }, headers: auth_headers(admin)

      expect(json).to include("match_state" => "matched", "tmdb_id" => 841, "year" => 1984)
      expect(movie.reload.match_reasons["summary"]).to include("chosen by")
    end

    it "says so when TMDB is down instead of failing silently" do
      stub_request(:get, %r{/movie/841}).to_return(status: 503)
      post "/api/v1/matches/movie/#{movie.id}", params: { tmdb_id: 841 }, headers: auth_headers(admin)
      expect(response).to have_http_status(:bad_gateway)
      expect(json["errors"].join).to include("TMDB")
    end
  end
  describe "shows filed from more than one folder" do
    let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
    let(:bluey) do
      Show.create!(household: household, library: tv, folder: "Bluey", title: "Bluey", tmdb_id: 82_728,
        match_state: "matched").tap { |show| show.folders.create!(household: household, library: tv, folder: "Bluey (2018)") }
    end

    it "lists them for the grown-ups, with each folder's paths" do
      Show.create!(household: household, library: tv, folder: "Severance", title: "Severance")
      bluey

      get "/api/v1/matches/folders", headers: auth_headers(member)

      expect(json.sole).to include("id" => bluey.id, "title" => "Bluey")
      expect(json.sole["folders"]).to eq([
        { "folder" => "Bluey", "paths" => [ File.join(tv.roots.first, "Bluey") ] },
        { "folder" => "Bluey (2018)", "paths" => [ File.join(tv.roots.first, "Bluey (2018)") ] }
      ])
    end

    it "lets an admin say a folder isn't this show" do
      post "/api/v1/matches/show/#{bluey.id}/reject", params: { folder: "Bluey (2018)" }, headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/matches/show/#{bluey.id}/reject", params: { folder: "Elsewhere" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:not_found)

      post "/api/v1/matches/show/#{bluey.id}/reject", params: { folder: "Bluey (2018)" }, headers: auth_headers(admin)
      expect(json).to include("kind" => "show", "folder" => "Bluey (2018)", "match_state" => "needs_review")
      expect(bluey.reload.folders.map(&:folder)).to eq([ "Bluey" ])
    end
  end
end
