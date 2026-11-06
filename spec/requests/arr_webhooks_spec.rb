# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sonarr/Radarr webhooks", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:tv_root) { build_root("Severance (2022)/Season 01/S01E01.mkv" => "h264_aac.mp4") }
  let(:movies_root) { build_root("Heat (1995)/Heat.mkv" => "h264_aac.mp4") }
  let!(:tv) { create_library(household: household, roots: tv_root, kind: "shows", name: "TV") }
  let!(:movies) { create_library(household: household, roots: movies_root, name: "Movies") }
  let(:webhook) { ArrWebhook.for(household) }

  before do
    PathMapping.create!(household: household, remote_prefix: "/tv", local_prefix: tv_root)
    PathMapping.create!(household: household, remote_prefix: "/movies/", local_prefix: movies_root)
    clear_enqueued_jobs
  end

  def deliver(payload, token: webhook.token)
    post "/hooks/arr/#{token}", params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  def scans = enqueued_jobs.select { |job| job["job_class"] == "ScanLibraryJob" }.map { |job| job["arguments"] }

  it "scans the series folder Sonarr just imported into, translated through the path mapping" do
    deliver({ "eventType" => "Download", "series" => { "title" => "Severance", "path" => "/tv/Severance (2022)" },
      "episodeFile" => { "path" => "/tv/Severance (2022)/Season 01/S01E01.mkv" } })

    expect(response).to have_http_status(:ok)
    expect(scans).to eq([ [ tv.id, File.join(tv_root, "Severance (2022)") ] ])
    expect(webhook.reload).to have_attributes(last_source: "Sonarr", last_event: "Download")
  end

  it "adds a file once however often Sonarr retries the same import" do
    payload = { "eventType" => "Download", "series" => { "title" => "Severance", "path" => "/tv/Severance (2022)" },
                "episodeFile" => { "path" => "/tv/Severance (2022)/Season 01/S01E01.mkv" } }

    require_ffprobe!
    perform_enqueued_jobs(only: [ ScanLibraryJob, ProbeMediaFileJob ]) do
      3.times { deliver(payload) }
    end

    expect(response).to have_http_status(:ok)
    file = MediaFile.where(library: tv).sole
    expect(file).to have_attributes(path: File.join(tv_root, "Severance (2022)/Season 01/S01E01.mkv"), state: "probed")
    expect(file.analysis_runs.where(step: "probe").sole.status).to eq("succeeded")
    expect(ActivityEntry.where(event: "library.scanned").count).to eq(1) # the later scans found nothing new
  end

  it "scans the movie folder Radarr names" do
    deliver({ "eventType" => "Download", "movie" => { "title" => "Heat", "folderPath" => "/movies/Heat (1995)" } })
    expect(scans).to eq([ [ movies.id, File.join(movies_root, "Heat (1995)") ] ])
  end

  it "scans the library root when a deleted series' folder is already gone" do
    deliver({ "eventType" => "SeriesDelete", "series" => { "path" => "/tv/Gone Show" } })
    expect(scans).to eq([ [ tv.id, tv_root ] ])
  end

  it "says which path no library holds, and how to fix it" do
    deliver({ "eventType" => "Download", "series" => { "path" => "/anime/Frieren" } })

    expect(scans).to be_empty
    expect(json["message"]).to include("no library holds /anime/Frieren", "path mapping")
    expect(ActivityEntry.where(event: "arr.download").sole.severity).to eq("warn")
  end

  it "answers Connect's Test button and ignores events that change nothing on disk" do
    deliver({ "eventType" => "Test", "series" => {} })
    expect(json["message"]).to eq("Test received from Sonarr")

    deliver({ "eventType" => "Grab", "movie" => { "folderPath" => "/movies/Heat (1995)" } })
    expect(scans).to be_empty
  end

  it "refuses an unknown token and junk bodies" do
    deliver({ "eventType" => "Test" }, token: "wrong")
    expect(response).to have_http_status(:not_found)

    post "/hooks/arr/#{webhook.token}", params: "not json", headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:bad_request)
  end

  describe "settings" do
    it "shows the URL to paste, regenerates it, and manages mappings" do
      get "/api/v1/arr_webhook", headers: auth_headers(admin)
      old_url = json["url"]
      expect(old_url).to end_with("/hooks/arr/#{webhook.token}")
      expect(json["path_mappings"].map { |m| m["remote_prefix"] }).to eq([ "/movies", "/tv" ])

      post "/api/v1/arr_webhook/regenerate", headers: auth_headers(admin)
      expect(json["url"]).not_to eq(old_url)

      post "/api/v1/arr_webhook/path_mappings", params: { path_mapping: { remote_prefix: "/anime", local_prefix: "/not/mounted" } },
        headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].join).to include("isn't visible to Stream")
    end

    it "is an admin's alone" do
      get "/api/v1/arr_webhook", headers: auth_headers(create_user(household: household))
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "translates with the longest matching prefix, on a path-segment boundary" do
    PathMapping.create!(household: household, remote_prefix: "/tv/kids", local_prefix: movies_root)
    expect(PathMapping.translate(household.id, "/tv/kids/Bluey")).to eq(File.join(movies_root, "Bluey"))
    expect(PathMapping.translate(household.id, "/tv/Severance")).to eq(File.join(tv_root, "Severance"))
    expect(PathMapping.translate(household.id, "/tvshows/X")).to eq("/tvshows/X")
  end
end
