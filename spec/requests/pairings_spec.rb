# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Device pairing", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:tv) { { "User-Agent" => "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 Chrome/85.0 TV Safari/537.36" } }

  it "signs a TV in once someone signed in enters its code, handing the session over exactly once" do
    post "/api/v1/pairings", headers: tv
    expect(response).to have_http_status(:created)
    code = json["code"]
    poll = json["poll_token"]
    expect(code).to match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/)

    get "/api/v1/pairings/#{poll}"
    expect(json).to eq("state" => "pending")

    post "/api/v1/pairings/approve", params: { code: code.downcase.delete("-") }, headers: auth_headers(user)
    expect(response).to have_http_status(:ok)

    get "/api/v1/pairings/#{poll}"
    expect(json).to include("state" => "approved", "user" => include("id" => user.id))
    token = json["token"]
    get "/api/v1/profiles/current", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:ok)
    expect(ApiSession.find_by(token: token).device).to start_with("TV — ")

    get "/api/v1/pairings/#{poll}"
    expect(response).to have_http_status(:gone)
  end

  it "won't approve an expired or made-up code, and the code alone doesn't poll" do
    post "/api/v1/pairings"
    code = json["code"]
    DevicePairing.last.update!(expires_at: 1.minute.ago)
    post "/api/v1/pairings/approve", params: { code: code }, headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/pairings/approve", params: { code: "ZZZZ-ZZZZ" }, headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)

    get "/api/v1/pairings/#{code}"
    expect(response).to have_http_status(:not_found)
  end

  it "needs a signed-in person to approve" do
    post "/api/v1/pairings"
    post "/api/v1/pairings/approve", params: { code: json["code"] }
    expect(response).to have_http_status(:unauthorized)
  end

  it "takes a native client's own name for itself" do
    post "/api/v1/pairings", params: { device_label: "Apple TV (Living Room)" }, headers: { "User-Agent" => "StreamTV/1.0 (tvOS 17)" }
    expect(DevicePairing.find_by(poll_token: json["poll_token"]).device_label).to eq("Apple TV (Living Room)")
    expect(Device.name_from("StreamTV/1.0 (tvOS 17)")).to eq("Apple TV app")
  end
end
