# typed: false
# frozen_string_literal: true

require "rails_helper"

# fog:docs/files-contract.md — the notice, and the folders fog offers as
# libraries.
RSpec.describe "fog-files/1", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:fog) { "http://fog.test:8080" }

  around do |example|
    saved = ENV.to_h.slice("FOG_API_TOKEN", "FOG_API_URL")
    ENV["FOG_API_TOKEN"] = "fog-secret"
    ENV["FOG_API_URL"] = fog
    example.run
  ensure
    %w[FOG_API_TOKEN FOG_API_URL].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def fog_mounts(*mounts)
    stub_request(:get, "#{fog}/app/v1/files/mounts").with(headers: { "Authorization" => "Bearer fog-secret" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
        body: { mounts: mounts.map { |mount, host| { mount: mount, hostPath: host, kind: "local", readOnly: false } } }.to_json)
  end

  describe "the notice" do
    it "401s without fog's token" do
      post "/fog/files/changed", params: { mount: "/media/movies", reason: "changed" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "scans each library reading the folder that changed, and only those" do
      movies = build_root("a.mp4" => "h264_aac.mp4")
      shows = build_root("b.mp4" => "h264_aac.mp4")
      lib = Library.create!(household: household, name: "Movies", kind: "movies", roots: [ movies ])
      Library.create!(household: household, name: "TV", kind: "shows", roots: [ shows ])
      clear_enqueued_jobs

      post "/fog/files/changed", params: { mount: movies, reason: "synced" }, headers: { "Authorization" => "Bearer fog-secret" }

      expect(response).to have_http_status(:ok)
      scans = enqueued_jobs.select { |job| job["job_class"] == "ScanLibraryJob" }
      expect(scans.map { |job| job["arguments"] }).to eq([ [ lib.id, movies ] ])
    end
  end

  describe "folders from fog" do
    it "offers each mount no library reads, joined to the only library of its kind" do
      movies = build_root("a.mp4" => "h264_aac.mp4")
      stock = build_root("b.mp4" => "h264_aac.mp4")
      existing = Library.create!(household: household, name: "Films", kind: "movies", roots: [ stock ])
      fog_mounts([ movies, "/srv/files/Content/Movies" ], [ "/media/tv", "/srv/files/Content/TV" ],
        [ stock, "/mnt/stock" ], [ "/media/odd", "/srv/files/Content/Scans" ])

      get "/api/v1/libraries/fog_suggestions", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json).to eq([
        { "root" => movies, "name" => "Movies", "kind" => "movies", "library_id" => existing.id, "library_name" => "Films" },
        { "root" => "/media/tv", "name" => "TV", "kind" => "shows", "library_id" => nil, "library_name" => nil }
      ])
    end

    it "offers nothing outside fog" do
      ENV.delete("FOG_API_URL")
      get "/api/v1/libraries/fog_suggestions", headers: auth_headers(admin)
      expect(json).to eq([])
    end

    it "is for admins" do
      get "/api/v1/libraries/fog_suggestions", headers: auth_headers(create_user(household: household))
      expect(response).to have_http_status(:forbidden)
    end
  end

  # A Sonarr fog runs needs no hand-entered mapping: fog's translation
  # applies when no row of Stream's own does.
  it "translates an arr path through fog's connections when no mapping holds it" do
    stub_request(:get, "#{fog}/app/v1/connections").to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { connections: [ { app: "sonarr", paths: [ { remote: "/data/TV", local: "/media/tv" } ], unseen: [] } ] }.to_json)
    Rails.cache.delete("fog:path_rows")

    expect(PathMapping.translate(household.id, "/data/TV/Slow Horses")).to eq("/media/tv/Slow Horses")
    expect(PathMapping.translate(household.id, "/elsewhere/x")).to eq("/elsewhere/x")
  end
end
