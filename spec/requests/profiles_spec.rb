# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Profiles", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let!(:everyone) { Profile.default_for(household) }
  let(:device) { { "X-Stream-Device" => "living-room-tv" } }

  def current(headers) = get("/api/v1/profiles/current", headers: headers)

  it "lets an admin make a PIN'd profile, which only its PIN opens, and never by just naming it" do
    post "/api/v1/profiles", params: { name: "Alex", color: "#3366cc", avatar: "🦊", pin: "4321" }, headers: auth_headers(admin)
    expect(json).to include("name" => "Alex", "has_pin" => true, "avatar" => "🦊")
    alex = Profile.find(json["id"])

    current(auth_headers(member).merge("X-Stream-Profile" => alex.id))
    expect(json["profile"]["id"]).to eq(everyone.id)
    expect(json["needs_picker"]).to be(true)

    post "/api/v1/profiles/#{alex.id}/select", params: { pin: "0000" }, headers: auth_headers(member)
    expect(response).to have_http_status(:unauthorized)
    post "/api/v1/profiles/#{alex.id}/select", params: { pin: "4321" }, headers: auth_headers(member)
    token = json["token"]

    current(auth_headers(member).merge("X-Stream-Profile" => token))
    expect(json).to include("chosen" => true, "needs_picker" => false)
    expect(json["profile"]["id"]).to eq(alex.id)

    # A new PIN makes the old choice stale.
    patch "/api/v1/profiles/#{alex.id}", params: { pin: "9999" }, headers: auth_headers(admin)
    current(auth_headers(member).merge("X-Stream-Profile" => token))
    expect(json["profile"]["id"]).to eq(everyone.id)
  end

  it "waits after five wrong PINs" do
    kid = Profile.create!(household: household, name: "Kid", pin: "1234")
    5.times { post "/api/v1/profiles/#{kid.id}/select", params: { pin: "0000" }, headers: auth_headers(member) }
    post "/api/v1/profiles/#{kid.id}/select", params: { pin: "1234" }, headers: auth_headers(member)
    expect(response).to have_http_status(:too_many_requests)
  end

  it "loads a device straight into its default profile, no picker" do
    kids = Profile.create!(household: household, name: "Kids")
    post "/api/v1/profiles/#{kids.id}/select", params: { make_default: true }, headers: auth_headers(member).merge(device)

    current(auth_headers(member).merge(device))
    expect(json).to include("needs_picker" => false, "device_default_id" => kids.id)
    expect(json["profile"]["id"]).to eq(kids.id)
  end

  it "keeps a PIN'd profile out of the no-choice default, and one profile always" do
    everyone.update!(pin: "1111")
    open = Profile.create!(household: household, name: "Guests")
    current(auth_headers(member))
    expect(json["profile"]["id"]).to eq(open.id)

    delete "/api/v1/profiles/#{open.id}", headers: auth_headers(admin)
    delete "/api/v1/profiles/#{everyone.id}", headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/profiles", params: { name: "Mine" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end
end
