# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "A bundle an older build named", type: :request do
  it "answers a missing script with one that reloads into the current build" do
    get "/assets/index-GONE1234.js"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/javascript")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body).to include('fetch(path, { cache: "reload"', "location.reload()")
  end

  it "still 404s a missing stylesheet" do
    get "/assets/index-GONE1234.css"
    expect(response).to have_http_status(:not_found)
  end
end
