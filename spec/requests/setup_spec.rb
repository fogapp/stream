# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Setup", type: :request do
  describe "GET /api/v1/setup" do
    it "reports setup required on a fresh install" do
      get "/api/v1/setup"
      expect(response).to have_http_status(:ok)
      expect(json["setup_required"]).to be(true)
    end

    it "reports setup done once a user exists" do
      create_user(household: create_household)
      get "/api/v1/setup"
      expect(json["setup_required"]).to be(false)
    end
  end

  describe "POST /api/v1/setup" do
    it "creates household + admin and returns a session token" do
      post "/api/v1/setup", params: {
        household_name: "Rivers", email: "alex@example.com", name: "Alex", password: "passwordpassword"
      }
      expect(response).to have_http_status(:created)
      expect(json["token"]).to be_present
      expect(json.dig("user", "role")).to eq("admin")
      expect(Household.sole.name).to eq("Rivers")
    end

    it "refuses once any user exists" do
      create_user(household: create_household)
      post "/api/v1/setup", params: {
        household_name: "X", email: "x@example.com", name: "X", password: "passwordpassword"
      }
      expect(response).to have_http_status(:forbidden)
      expect(json["errors"]).to be_present
    end

    it "400s on missing params instead of 500ing" do
      post "/api/v1/setup", params: { household_name: "X" }
      expect(response).to have_http_status(:bad_request)
    end

    it "renders validation errors for a weak password" do
      post "/api/v1/setup", params: {
        household_name: "X", email: "x@example.com", name: "X", password: "short"
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].join).to include("Password")
    end
  end

  describe "POST /api/v1/setup/restore" do
    after { FileUtils.rm_rf(FogBackup::Staging.root) }

    def build_artifact
      dir = Pathname.new(Dir.mktmpdir)
      payload = "dump bytes"
      manifest = {
        format: "fog-backup/2", app: "stream",
        created_at: Time.current.utc.iso8601,
        produced_by: { git_sha: "abc123", schema_version: FogBackup::Manifest.code_schema_version.to_s },
        pg: { server_major: 18, extensions: {} },
        components: [ { name: "primary", path: "db/primary.dump", kind: "db",
                        bytes: payload.bytesize, sha256: Digest::SHA256.hexdigest(payload) } ],
        external: [], excluded: %w[cache queue],
        identity: { host: nil, webauthn_rp_id: nil }, secrets_fingerprint: {}
      }
      dir.join("db").mkpath
      dir.join("manifest.json").write(JSON.generate(manifest))
      dir.join("db/primary.dump").write(payload)
      system("tar", "-cf", dir.join("artifact.tar").to_s, "-C", dir.to_s,
        "manifest.json", "db/primary.dump", exception: true)
      Rack::Test::UploadedFile.new(dir.join("artifact.tar").to_s, "application/x-tar")
    end

    it "refuses once a user exists" do
      create_user(household: create_household)
      post "/api/v1/setup/restore", params: { artifact: build_artifact }
      expect(response).to have_http_status(:forbidden)
    end

    it "requires an artifact file" do
      post "/api/v1/setup/restore"
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a bad artifact and leaves nothing armed" do
      post "/api/v1/setup/restore", params: {
        artifact: Rack::Test::UploadedFile.new(StringIO.new("junk"), "application/x-tar", original_filename: "junk.tar")
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(FogBackup::Staging.armed?).to be(false)
    end

    it "stages, arms, and schedules the restart for a good artifact" do
      allow(FogBackup::Restart).to receive(:schedule!)

      post "/api/v1/setup/restore", params: { artifact: build_artifact }

      expect(response).to have_http_status(:ok)
      expect(json["restarting"]).to be(true)
      expect(FogBackup::Staging.armed?).to be(true)
      expect(FogBackup::Restart).to have_received(:schedule!)
    end
  end
end
