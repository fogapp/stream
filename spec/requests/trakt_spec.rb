# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trakt", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:headers) { auth_headers(admin) }
  let(:profile) { Profile.default_for(household) }

  def set_up_app
    patch "/api/v1/trakt_setting", params: { trakt_setting: { client_id: "client-abc", client_secret: "secret-xyz" } }, headers: headers,
      as: :json
  end

  describe "Settings › Integrations" do
    it "saves the app without ever sending the secret back" do
      set_up_app
      expect(json).to include("configured" => true, "client_id" => "client-abc")
      expect(response.body).not_to include("secret-xyz")
    end

    it "tests the client id" do
      set_up_app
      stub_request(:get, "https://api.trakt.tv/genres/movies").with(headers: { "trakt-api-key" => "client-abc" })
        .to_return(status: 403, body: "")
      post "/api/v1/trakt_setting/test", headers: headers
      expect(json).to include("ok" => false, "message" => "Trakt didn't accept that client ID.")
    end

    it "is an admin's alone" do
      get "/api/v1/trakt_setting", headers: auth_headers(create_user(household: household))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "linking a profile" do
    let(:watching) { headers.merge(profile_header(profile)) }

    it "says when there's no Trakt app to link through" do
      get "/api/v1/trakt_account", headers: watching
      expect(json).to eq("available" => false, "account" => nil)
      post "/api/v1/trakt_account", headers: watching
      expect(response).to have_http_status(:conflict)
    end

    it "shows a code, then links once it's entered at Trakt" do
      set_up_app
      stub_request(:post, "https://api.trakt.tv/oauth/device/code").with(body: { client_id: "client-abc" })
        .to_return(status: 200, body: { device_code: "dev-1", user_code: "ABCD1234", verification_url: "https://trakt.tv/activate",
                                        expires_in: 600, interval: 5 }.to_json)
      post "/api/v1/trakt_account", headers: watching
      expect(json["account"]).to include("state" => "pending", "user_code" => "ABCD1234", "verification_url" => "https://trakt.tv/activate")

      token = stub_request(:post, "https://api.trakt.tv/oauth/device/token")
        .with(body: { code: "dev-1", client_id: "client-abc", client_secret: "secret-xyz" })
        .to_return({ status: 400, body: "" },
          { status: 200, body: { access_token: "at-1", refresh_token: "rt-1", expires_in: 86_400, created_at: Time.current.to_i }.to_json })
      stub_request(:get, "https://api.trakt.tv/users/settings").with(headers: { "Authorization" => "Bearer at-1" })
        .to_return(status: 200, body: { user: { username: "alex" } }.to_json)

      post "/api/v1/trakt_account/poll", headers: watching
      expect(json["account"]).to include("state" => "pending")
      # Not faster than Trakt asked.
      post "/api/v1/trakt_account/poll", headers: watching
      expect(token).to have_been_requested.once

      travel 6.seconds do
        post "/api/v1/trakt_account/poll", headers: watching
      end
      expect(json["account"]).to include("state" => "linked", "username" => "alex", "user_code" => nil)
      expect(response.body).not_to include("at-1", "rt-1")
      expect(profile.reload.trakt_account.access_token).to eq("at-1")
    end

    it "unlinks, revoking the token at Trakt" do
      set_up_app
      TraktAccount.create!(household: household, profile: profile, state: "linked", access_token: "at-1", refresh_token: "rt-1",
        expires_at: 1.day.from_now)
      revoke = stub_request(:post, "https://api.trakt.tv/oauth/revoke").to_return(status: 200, body: "")
      delete "/api/v1/trakt_account", headers: watching
      expect(json).to eq("available" => true, "account" => nil)
      expect(revoke).to have_been_requested
    end

    it "is not for kid profiles" do
      set_up_app
      kid = Profile.create!(household: household, name: "Kid", kind: "kid")
      get "/api/v1/trakt_account", headers: headers.merge(profile_header(kid))
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "goes with its household" do
    set_up_app
    TraktAccount.create!(household: household, profile: profile, state: "linked")
    household.destroy!
    expect([ TraktSetting.count, TraktAccount.count ]).to eq([ 0, 0 ])
  end
end
