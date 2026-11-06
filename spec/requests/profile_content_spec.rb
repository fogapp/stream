# typed: false
# frozen_string_literal: true

require "rails_helper"

# Hiding a title from a profile (Settings › Profiles, and "Hide from me" on
# a title's page): gone from that profile's lists, search and page, back
# when unhidden; an admin manages anyone's, a profile its own, a kid none.
RSpec.describe "Profile content", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let!(:everyone) { Profile.default_for(household) }
  let(:alex) { Profile.create!(household: household, name: "Alex") }
  let(:movies) { create_library(household: household, roots: build_root, name: "Movies") }
  let(:tube) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }
  let!(:heat) { movie("Heat", 1995) }
  let!(:alien) { movie("Alien", 1979) }
  let!(:tc) { Channel.create!(household: household, library: tube, folder: "TC", title: "Technology Connections", handle: "@tc") }

  def movie(title, year)
    Movie.create!(household: household, library: movies, title: title, year: year).tap do |movie|
      file = MediaFile.create!(household: household, library: movies, path: "/m/#{title}.mkv", size: 1, mtime: Time.current, state: "probed")
      movie.editions.create!(media_file: file)
    end
  end

  def headers(user, profile) = auth_headers(user).merge(profile_header(profile))

  def hide(user, as:, target:, kind:, id:, hidden: true)
    put "/api/v1/profiles/#{target.id}/content/hidden", params: { kind: kind, id: id, hidden: hidden }, headers: headers(user, as)
  end

  def movie_titles(profile)
    get "/api/v1/movies", headers: headers(admin, profile)
    json.map { |row| row["title"] }.sort
  end

  it "hides a movie and a channel from one profile everywhere, and brings them back" do
    hide(member, as: alex, target: alex, kind: "movie", id: heat.id)
    expect(response).to have_http_status(:ok)
    hide(member, as: alex, target: alex, kind: "channel", id: tc.id)
    expect(json["hidden"].map { |item| item.slice("kind", "title", "detail") }).to eq([
      { "kind" => "channel", "title" => "Technology Connections", "detail" => "@tc" },
      { "kind" => "movie", "title" => "Heat", "detail" => "1995" }
    ])
    expect(json).not_to have_key("tagged")

    expect(movie_titles(alex)).to eq(%w[Alien])
    expect(movie_titles(everyone)).to eq(%w[Alien Heat])
    get "/api/v1/movies/#{heat.id}", headers: headers(member, alex)
    expect(response).to have_http_status(:not_found)
    get "/api/v1/search", params: { q: "heat" }, headers: headers(member, alex)
    expect(json["movies"]).to eq([])
    get "/api/v1/channels/#{tc.id}", headers: headers(member, alex)
    expect(response).to have_http_status(:not_found)

    hide(member, as: alex, target: alex, kind: "movie", id: heat.id, hidden: false)
    expect(json["hidden"].map { |item| item["title"] }).to eq([ "Technology Connections" ])
    expect(movie_titles(alex)).to eq(%w[Alien Heat])
  end

  it "lets an admin manage another profile and see what's tagged for it" do
    ProfileTag.create!(profile: alex, taggable: alien)
    hide(admin, as: everyone, target: alex, kind: "movie", id: heat.id)
    expect(response).to have_http_status(:ok)

    get "/api/v1/profiles/#{alex.id}/content", headers: headers(admin, everyone)
    expect(json["hidden"].map { |item| item["title"] }).to eq(%w[Heat])
    expect(json["tagged"].map { |item| item["title"] }).to eq(%w[Alien])
  end

  it "keeps a member to their own profile, and a kid out entirely" do
    hide(member, as: everyone, target: alex, kind: "movie", id: heat.id)
    expect(response).to have_http_status(:forbidden)

    kid = Profile.create!(household: household, name: "Kid", kind: "kid")
    hide(member, as: kid, target: kid, kind: "movie", id: heat.id)
    expect(response).to have_http_status(:forbidden)
    hide(admin, as: kid, target: kid, kind: "movie", id: heat.id)
    expect(response).to have_http_status(:forbidden)
    expect(ProfileExclusion.count).to eq(0)
  end

  it "only hides what the one hiding can see" do
    other = create_household
    elsewhere = Movie.create!(household: other, library: create_library(household: other, roots: build_root), title: "Elsewhere")
    hide(admin, as: everyone, target: alex, kind: "movie", id: elsewhere.id)
    expect(response).to have_http_status(:not_found)
    hide(admin, as: everyone, target: alex, kind: "album", id: heat.id)
    expect(response).to have_http_status(:not_found)
  end
end
