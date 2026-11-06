# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Libraries", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }

  it "creates a library from validated roots and queues its first scan" do
    root = build_root("a.mp4" => "h264_aac.mp4")

    post "/api/v1/libraries", params: { library: { name: "Movies", kind: "movies", roots: [ "#{root}/" ] } },
      headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:created)
    expect(json).to include("name" => "Movies", "kind" => "movies", "roots" => [ root ], "scanning" => false)
    expect(json["file_counts"]).to include("discovered" => 0, "probed" => 0)
    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("ScanLibraryJob")
  end

  it "explains a root Stream can't see instead of saving it" do
    post "/api/v1/libraries", params: { library: { name: "Movies", kind: "movies", roots: [ "/nope/not/mounted" ] } },
      headers: auth_headers(admin), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].join).to include("isn't visible to Stream")
  end

  it "refuses nested roots and unknown kinds" do
    root = build_root("sub/a.mp4" => "h264_aac.mp4")
    post "/api/v1/libraries", params: { library: { name: "M", kind: "movies", roots: [ root, File.join(root, "sub") ] } },
      headers: auth_headers(admin), as: :json
    expect(json["errors"].join).to include("can't contain one another")

    post "/api/v1/libraries", params: { library: { name: "M", kind: "podcasts", roots: [ root ] } },
      headers: auth_headers(admin), as: :json
    expect(json["errors"].join).to include("Kind")
  end

  it "lets members read but not change libraries" do
    library = create_library(household: household, roots: build_root)

    get "/api/v1/libraries", headers: auth_headers(member)
    expect(json.map { |row| row["id"] }).to eq([ library.id ])

    patch "/api/v1/libraries/#{library.id}", params: { library: { name: "x" } }, headers: auth_headers(member), as: :json
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/libraries/#{library.id}/scan", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end

  it "never shows another household's libraries" do
    create_library(household: create_household(name: "Other"), roots: build_root)
    get "/api/v1/libraries", headers: auth_headers(member)
    expect(json).to eq([])
  end

  it "queues a targeted scan only for a path inside the library" do
    root = build_root("Show/e1.mkv" => "h264_aac.mp4")
    library = create_library(household: household, roots: root, kind: "shows")

    post "/api/v1/libraries/#{library.id}/scan", params: { path: File.join(root, "Show") }, headers: auth_headers(admin)
    expect(response).to have_http_status(:accepted)
    expect(enqueued_jobs.last["arguments"]).to eq([ library.id, File.join(root, "Show") ])

    post "/api/v1/libraries/#{library.id}/scan", params: { path: "/etc" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "validates a folder for the form" do
    post "/api/v1/libraries/validate_path", params: { path: build_root }, headers: auth_headers(admin)
    expect(json).to include("ok" => true, "exists" => true)

    post "/api/v1/libraries/validate_path", params: { path: "relative/path" }, headers: auth_headers(admin)
    expect(json).to include("ok" => false)
  end

  it "rescans when the roots change" do
    library = create_library(household: household, roots: build_root)
    clear_enqueued_jobs

    patch "/api/v1/libraries/#{library.id}", params: { library: { name: "Films" } }, headers: auth_headers(admin), as: :json
    expect(enqueued_jobs).to be_empty

    patch "/api/v1/libraries/#{library.id}", params: { library: { roots: [ build_root ] } }, headers: auth_headers(admin), as: :json
    expect(enqueued_jobs.map { |job| job["job_class"] }).to eq([ "ScanLibraryJob" ])
  end

  describe "media files" do
    it "lists files by state and shows the analysis checklist" do
      library = create_library(household: household, roots: build_root)
      file = MediaFile.create!(household: household, library: library, path: "/x/a.mkv", size: 1, mtime: Time.current,
        state: "broken", last_error: "Invalid data")

      get "/api/v1/media_files", params: { state: "broken" }, headers: auth_headers(member)
      expect(json.map { |row| row["id"] }).to eq([ file.id ])
      get "/api/v1/media_files", params: { state: "probed" }, headers: auth_headers(member)
      expect(json).to eq([])

      get "/api/v1/media_files/#{file.id}", headers: auth_headers(member)
      expect(json["analysis"].map { |run| run["step"] }).to eq(AnalysisRun::Step.values.map(&:serialize))
      expect(json["analysis"].map { |run| run["status"] }).to all(eq("pending"))
    end
  end
end
