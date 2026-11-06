# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API tokens", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:other) { create_user(household: household) }

  describe "management" do
    it "mints a token, reveals the plaintext once, and lists it without it" do
      post "/api/v1/api_tokens", params: { name: "Claude", expires_in_days: 30 }, headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      expect(json["token"]).to start_with("stream_")
      expect(json).to include("name" => "Claude", "expired" => false)
      expect(Time.iso8601(json["expires_at"])).to be_within(1.minute).of(30.days.from_now)

      get "/api/v1/api_tokens", headers: auth_headers(user)
      expect(json.length).to eq(1)
      expect(json.first).not_to have_key("token")
      expect(json.first["prefix"]).to start_with("stream_")
      expect(json.first["scope"]).to eq("full")
    end

    it "validates the expiry window" do
      post "/api/v1/api_tokens", params: { name: "x", expires_in_days: 0 }, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].join).to include("between 1 and")

      post "/api/v1/api_tokens", params: { name: "x", expires_in_days: ApiToken::MAX_EXPIRES_IN_DAYS + 1 }, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "renders model errors for a blank name" do
      post "/api/v1/api_tokens", params: { name: "" }, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"].join).to include("Name")
    end

    it "only shows and deletes the caller's own tokens" do
      mine = ApiToken.generate(user: user, name: "mine").api_token
      theirs = ApiToken.generate(user: other, name: "theirs").api_token

      get "/api/v1/api_tokens", headers: auth_headers(user)
      expect(json.map { |t| t["id"] }).to eq([ mine.id ])

      delete "/api/v1/api_tokens/#{theirs.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
      expect(ApiToken.exists?(theirs.id)).to be(true)

      delete "/api/v1/api_tokens/#{mine.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:no_content)
      expect(ApiToken.exists?(mine.id)).to be(false)
    end
  end

  describe "authentication with a token" do
    it "authenticates a request as the token's owner" do
      token = ApiToken.generate(user: user, name: "Claude").token
      get "/api/v1/me", headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to have_http_status(:ok)
      expect(json["id"]).to eq(user.id)
      expect(ApiToken.first.last_used_at).to be_present
    end

    it "lets a read-only token look but not change" do
      admin = create_user(household: household, role: "admin")
      token = ApiToken.generate(user: admin, name: "wall", scope: ApiToken::Scope::Read).token
      headers = { "Authorization" => "Bearer #{token}" }

      get "/api/v1/stats/now_playing", headers: headers
      expect(response).to have_http_status(:ok)

      post "/api/v1/api_tokens", params: { name: "another" }, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(json["errors"].first).to eq("This token is read-only")
      expect(ApiToken.count).to eq(1)

      # A POST that only looks is open to it.
      post "/api/v1/youtube/resolve", params: { url: "" }, headers: headers
      expect(response).not_to have_http_status(:forbidden)
    end

    it "rejects an expired or unknown token" do
      token = ApiToken.generate(user: user, name: "old", expires_at: 1.minute.ago).token
      get "/api/v1/me", headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to have_http_status(:unauthorized)

      get "/api/v1/me", headers: { "Authorization" => "Bearer stream_nope" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
