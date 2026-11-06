# typed: false
# frozen_string_literal: true

require "rails_helper"

# fog:docs/integrations-contract.md — the provider's surface.
RSpec.describe "fog-integration/1 surface", type: :request do
  let(:token) { "fog-test-token" }

  around do |example|
    previous = ENV["FOG_API_TOKEN"]
    ENV["FOG_API_TOKEN"] = token
    example.run
  ensure
    previous.nil? ? ENV.delete("FOG_API_TOKEN") : ENV["FOG_API_TOKEN"] = previous
  end

  def fog_headers = { "Authorization" => "Bearer #{token}" }

  def connect(offer, consumer: "hook")
    post "/fog/integrations", params: { consumer: consumer, offer: offer }, headers: fog_headers
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  it "rejects a wrong bearer" do
    post "/fog/integrations", params: { consumer: "hook", offer: "library" }, headers: { "Authorization" => "Bearer nope" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "with a household and its admin" do
    let!(:household) { create_household }
    let!(:admin) { create_user(household: household, role: "admin") }

    it "library mints a full token in the admin's name, which may change things" do
      connect("library")

      expect(response).to have_http_status(:created)
      expect(json["secrets"].keys).to eq([ "STREAM_API_TOKEN" ])
      minted = ApiToken.authenticate(json["secrets"]["STREAM_API_TOKEN"])
      expect(minted.scope_enum).to eq(ApiToken::Scope::Full)
      expect(minted.user).to eq(admin)
      expect(minted.name).to eq("fog: hook")

      post "/api/v1/api_tokens", params: { name: "made with it" }, headers: bearer(json["secrets"]["STREAM_API_TOKEN"])
      expect(response).to have_http_status(:created)
    end

    it "viewing mints a read-only token that looks as the admin and changes nothing" do
      connect("viewing", consumer: "newtab")

      expect(response).to have_http_status(:created)
      expect(json["secrets"].keys).to eq([ "STREAM_READ_TOKEN" ])
      secret = json["secrets"]["STREAM_READ_TOKEN"]
      minted = ApiToken.authenticate(secret)
      expect(minted).to be_read_only
      expect(minted.user).to eq(admin)
      expect(minted.name).to eq("fog: newtab")

      get "/api/v1/stats/now_playing", headers: bearer(secret)
      expect(response).to have_http_status(:ok)

      post "/api/v1/api_tokens", params: { name: "made with it" }, headers: bearer(secret)
      expect(response).to have_http_status(:forbidden)
      expect(json["errors"].first).to eq("This token is read-only")
    end

    it "refuses an offer it does not make, and a consumer that is not an app name" do
      connect("telemetry")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].first).to include("library, viewing")

      connect("library", consumer: "Not An App")
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].first).to include("not an app name")
      expect(ApiToken.count).to eq(0)
    end

    it "reports the token's use, and revokes it" do
      connect("library")
      id = json["id"]
      secret = json["secrets"]["STREAM_API_TOKEN"]

      get "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:ok)
      expect(json).to include("id" => id, "active" => true, "last_activity_at" => nil)
      expect(json["created_at"]).to be_present

      ApiToken.authenticate(secret).update!(last_used_at: 1.minute.ago)
      get "/fog/integrations/#{id}", headers: fog_headers
      expect(json["last_activity_at"]).to be_present

      delete "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:no_content)
      expect(ApiToken.authenticate(secret)).to be_nil
      expect(FogIntegration.exists?(id)).to be(false)

      get "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:not_found)
      delete "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:not_found)
    end

    it "shows a token a person revoked in Settings as inactive" do
      connect("viewing", consumer: "newtab")
      id = json["id"]
      ApiToken.authenticate(json["secrets"]["STREAM_READ_TOKEN"]).destroy!

      get "/fog/integrations/#{id}", headers: fog_headers
      expect(response).to have_http_status(:ok)
      expect(json["active"]).to be(false)
    end

    it "answers 404 for an integration it never made" do
      delete "/fog/integrations/#{SecureRandom.uuid}", headers: fog_headers
      expect(response).to have_http_status(:not_found)
      get "/fog/integrations/garbage", headers: fog_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  it "says to sign in once before there is an admin to hold the token" do
    household = create_household
    create_user(household: household, role: "member")
    connect("library")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("sign in")
    expect(ApiToken.count).to eq(0)
  end

  it "says to finish setup before there is a household" do
    connect("library")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"].first).to include("setup")
  end
end
