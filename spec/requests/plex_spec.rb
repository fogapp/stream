# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Import from Plex", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:headers) { auth_headers(admin) }

  def connect
    patch "/api/v1/plex_connection", params: { plex_connection: { server_url: "http://plex.lan:32400/", token: "secret-token" } },
      headers: headers, as: :json
  end

  it "saves the server without ever sending the token back" do
    connect
    expect(json).to include("connected" => true, "server_url" => "http://plex.lan:32400")
    expect(response.body).not_to include("secret-token")
  end

  it "tests the server and learns who's in the Plex Home, the owner mapped to the default profile" do
    connect
    stub_request(:get, "http://plex.lan:32400/identity")
      .to_return(status: 200, body: { MediaContainer: { machineIdentifier: "abc", friendlyName: "Den" } }.to_json)
    stub_request(:get, "http://plex.lan:32400/library/sections")
      .to_return(status: 200, body: { MediaContainer: { Directory: [ { key: "1", type: "movie" }, { key: "9", type: "artist" } ] } }.to_json)
    stub_request(:get, "https://plex.tv/api/v2/home/users").to_return(status: 200, body: { users: [
      { id: 1, uuid: "u1", title: "Alex", admin: true }, { id: 2, uuid: "u2", title: "Kid", admin: false, protected: true }
    ] }.to_json)

    post "/api/v1/plex_connection/test", headers: headers
    expect(json).to include("ok" => true, "message" => include("Den", "1 movie and TV libraries", "2 Plex users"))

    get "/api/v1/plex_connection", headers: headers
    users = json["users"]
    expect(users.map { |u| [ u["plex_name"], u["profile_id"] ] })
      .to eq([ [ "Alex", Profile.default_for(household).id ], [ "Kid", nil ] ])

    patch "/api/v1/plex_connection/users/#{users.last['id']}", params: { profile_id: "new" }, headers: headers
    expect(Profile.find(json["users"].last["profile_id"]).name).to eq("Kid")
  end

  it "queues a dry run, and refuses one with no server" do
    post "/api/v1/plex_imports", params: { dry_run: true }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)

    connect
    post "/api/v1/plex_imports", params: { dry_run: true }, headers: headers
    expect(json).to include("dry_run" => true, "status" => "queued")
    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("PlexImportJob")
  end

  it "is an admin's alone" do
    get "/api/v1/plex_connection", headers: auth_headers(create_user(household: household))
    expect(response).to have_http_status(:forbidden)
  end
end
