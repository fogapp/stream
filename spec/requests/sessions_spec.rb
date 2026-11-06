# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sessions", type: :request do
  let(:household) { create_household }
  let!(:user) { create_user(household: household, email: "m@example.com", password: "passwordpassword") }

  describe "POST /api/v1/session" do
    it "returns a token for valid credentials" do
      post "/api/v1/session", params: { email: "M@Example.com", password: "passwordpassword" }
      expect(response).to have_http_status(:created)
      expect(json["token"]).to be_present
      expect(json.dig("user", "email")).to eq("m@example.com")
    end

    it "401s with the errors envelope for bad credentials" do
      post "/api/v1/session", params: { email: "m@example.com", password: "wrong-password" }
      expect(response).to have_http_status(:unauthorized)
      expect(json["errors"]).to eq([ "Invalid email or password" ])
    end
  end

  describe "DELETE /api/v1/session" do
    it "revokes the session token" do
      headers = auth_headers(user)
      delete "/api/v1/session", headers: headers
      expect(response).to have_http_status(:no_content)
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/me" do
    it "returns the current user" do
      get "/api/v1/me", headers: auth_headers(user)
      expect(json["id"]).to eq(user.id)
    end

    it "401s without a token" do
      get "/api/v1/me"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
