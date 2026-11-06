# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sidebar", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let!(:everyone) { Profile.default_for(household) }
  let(:library_key) { "library:#{SecureRandom.uuid}" }

  it "starts unarranged, and keeps an order and a hidden set per profile" do
    get "/api/v1/sidebar", headers: auth_headers(user)
    expect(json).to eq("order" => [], "hidden" => [])

    put "/api/v1/sidebar", params: { order: [ library_key, "live", "playlists" ], hidden: [ "stats" ] }, headers: auth_headers(user), as: :json
    expect(json).to eq("order" => [ library_key, "live", "playlists" ], "hidden" => [ "stats" ])
    expect(everyone.reload.sidebar).to eq("order" => [ library_key, "live", "playlists" ], "hidden" => [ "stats" ])

    other = Profile.create!(household: household, name: "Kid", position: 1)
    get "/api/v1/sidebar", headers: auth_headers(user).merge(profile_header(other))
    expect(json).to eq("order" => [], "hidden" => [])
  end

  it "keeps only keys it recognizes, once each" do
    put "/api/v1/sidebar", params: { order: [ "live", "live", "../etc", "Live", "library:nope" ], hidden: "settings" },
      headers: auth_headers(user), as: :json
    expect(json).to eq("order" => [ "live" ], "hidden" => [ "settings" ])
  end
end
