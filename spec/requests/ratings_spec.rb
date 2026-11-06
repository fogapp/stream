# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ratings", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:movie) { Movie.create!(household: household, library: library, title: "Heat", year: 1995) }
  let(:kids) { Profile.create!(household: household, name: "Kids") }

  it "keeps each profile's own stars, and clears them" do
    put "/api/v1/rating", params: { rateable_type: "movie", rateable_id: movie.id, value: 8 }, headers: auth_headers(user)
    expect(json).to eq("value" => 8.0)
    put "/api/v1/rating", params: { rateable_type: "movie", rateable_id: movie.id, value: 4 },
      headers: auth_headers(user).merge(profile_header(kids))

    get "/api/v1/movies/#{movie.id}", headers: auth_headers(user)
    expect(json["my_rating"]).to eq(8.0)

    put "/api/v1/rating", params: { rateable_type: "movie", rateable_id: movie.id, value: "" }, headers: auth_headers(user)
    get "/api/v1/movies/#{movie.id}", headers: auth_headers(user)
    expect(json["my_rating"]).to be_nil
    expect(Rating.sole).to have_attributes(profile: kids, value: 4.0)
  end

  it "refuses a rating off the scale" do
    put "/api/v1/rating", params: { rateable_type: "movie", rateable_id: movie.id, value: 11 }, headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_content)
  end
end
