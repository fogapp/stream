# typed: false
# frozen_string_literal: true

require "rails_helper"
require "webauthn"
require "webauthn/fake_client"

# Drives both ceremonies with the gem's FakeClient. The relying party is
# derived from the request, so the fake client presents the origin Rack::Test
# requests come from.
RSpec.describe "Passkeys", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, email: "keys@example.com") }
  let(:origin) { "http://www.example.com" }
  let(:fake_client) { WebAuthn::FakeClient.new(origin) }

  def enrol!(nickname: "Laptop")
    post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    begin_body = json
    attestation = fake_client.create(challenge: begin_body.dig("options", "challenge"))
    post "/api/v1/webauthn_credentials/register/finish", headers: auth_headers(user),
      params: { credential: attestation, challenge_token: begin_body["challenge_token"], nickname: nickname }, as: :json
    expect(response).to have_http_status(:created)
    json
  end

  describe "enrolment" do
    it "needs a session" do
      post "/api/v1/webauthn_credentials/register/begin"
      expect(response).to have_http_status(:unauthorized)
    end

    it "issues creation options bound to the member and a signed challenge" do
      post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(user)
      expect(json.dig("options", "user", "name")).to eq("keys@example.com")
      expect(json.dig("options", "rp", "id")).to eq("www.example.com")
      expect(json["challenge_token"]).to be_present
    end

    it "stores the credential and lists it" do
      created = enrol!
      expect(created["nickname"]).to eq("Laptop")
      expect(user.webauthn_credentials.count).to eq(1)
      expect(ActivityEntry.where(event: "passkey.enrolled")).to exist

      get "/api/v1/webauthn_credentials", headers: auth_headers(user)
      expect(json.map { |c| c["nickname"] }).to eq([ "Laptop" ])
    end

    it "rejects a tampered or expired challenge with a 422, not a 500" do
      post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(user)
      attestation = fake_client.create(challenge: json.dig("options", "challenge"))
      post "/api/v1/webauthn_credentials/register/finish", headers: auth_headers(user),
        params: { credential: attestation, challenge_token: "nope" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].join).to include("challenge")
    end

    it "refuses a challenge minted for another member" do
      other = create_user(household: household)
      post "/api/v1/webauthn_credentials/register/begin", headers: auth_headers(other)
      begin_body = json
      attestation = fake_client.create(challenge: begin_body.dig("options", "challenge"))
      post "/api/v1/webauthn_credentials/register/finish", headers: auth_headers(user),
        params: { credential: attestation, challenge_token: begin_body["challenge_token"] }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "removes a passkey, even the last one — password sign-in remains" do
      created = enrol!
      delete "/api/v1/webauthn_credentials/#{created['id']}", headers: auth_headers(user)
      expect(response).to have_http_status(:no_content)
      expect(user.webauthn_credentials.count).to eq(0)
      expect(ActivityEntry.where(event: "passkey.removed")).to exist
    end

    it "only removes the member's own passkeys" do
      created = enrol!
      delete "/api/v1/webauthn_credentials/#{created['id']}", headers: auth_headers(create_user(household: household))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "sign-in" do
    before { enrol! }

    it "signs in with the enrolled passkey and mints a session" do
      post "/api/v1/auth/passkey/login/begin", params: { email: "keys@example.com" }, as: :json
      expect(response).to have_http_status(:ok)
      begin_body = json
      expect(begin_body.dig("options", "allowCredentials").length).to eq(1)

      assertion = fake_client.get(challenge: begin_body.dig("options", "challenge"))
      post "/api/v1/auth/passkey/login/finish",
        params: { credential: assertion, challenge_token: begin_body["challenge_token"] }, as: :json
      expect(response).to have_http_status(:created)
      expect(json["token"]).to be_present
      expect(json.dig("user", "email")).to eq("keys@example.com")
      expect(ApiSession.find_by(token: json["token"]).device).to start_with("passkey")
      expect(user.webauthn_credentials.sole.last_used_at).to be_present
    end

    it "works without an email (discoverable credential)" do
      post "/api/v1/auth/passkey/login/begin", as: :json
      begin_body = json
      expect(begin_body.dig("options", "allowCredentials")).to be_blank

      assertion = fake_client.get(challenge: begin_body.dig("options", "challenge"))
      post "/api/v1/auth/passkey/login/finish",
        params: { credential: assertion, challenge_token: begin_body["challenge_token"] }, as: :json
      expect(response).to have_http_status(:created)
    end

    it "rejects an unknown passkey" do
      stranger = WebAuthn::FakeClient.new(origin)
      # A credential the stranger created elsewhere: register it with a
      # throwaway challenge so the fake client knows it, then assert.
      stranger.create(challenge: WebAuthn::Credential.options_for_create(user: { id: "x", name: "x" }, relying_party: WebAuthn::RelyingParty.new(id: "www.example.com", allowed_origins: [ origin ])).challenge)
      post "/api/v1/auth/passkey/login/begin", as: :json
      begin_body = json
      assertion = stranger.get(challenge: begin_body.dig("options", "challenge"))
      post "/api/v1/auth/passkey/login/finish",
        params: { credential: assertion, challenge_token: begin_body["challenge_token"] }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json["errors"].join).to include("isn't registered")
    end

    it "rejects a stale challenge token" do
      post "/api/v1/auth/passkey/login/begin", as: :json
      assertion = fake_client.get(challenge: json.dig("options", "challenge"))
      post "/api/v1/auth/passkey/login/finish", params: { credential: assertion, challenge_token: "expired" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json["errors"].join).to include("expired")
    end
  end

  describe "backup identity" do
    it "records the RP id in the manifest when STREAM_HOST is set" do
      previous = ENV["STREAM_HOST"]
      ENV["STREAM_HOST"] = "stream.example.test"
      expect(FogBackup::Manifest.build(components: []).dig(:identity, :webauthn_rp_id)).to eq("stream.example.test")
    ensure
      ENV["STREAM_HOST"] = previous
    end
  end
end
