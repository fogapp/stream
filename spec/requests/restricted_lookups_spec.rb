# typed: false
# frozen_string_literal: true

require "rails_helper"

# The doors that used to look a thing up without asking Viewing::Access.
RSpec.describe "Lookups a restricted profile can't get past", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let!(:grown_up) { Profile.default_for(household) }
  let(:kid) { Profile.create!(household: household, name: "Younger", max_rating_age: 10, position: 1) }
  let(:headers) { auth_headers(admin).merge(profile_header(kid)) }
  let(:films) { create_library(household: household, roots: build_root, name: "Films") }
  let(:tube) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }

  def movie(title, rating)
    Movie.create!(household: household, library: films, title: title, content_rating: rating).tap do |film|
      file = MediaFile.create!(household: household, library: films, path: "/m/#{title}.mkv", size: 1, mtime: Time.current, state: "probed")
      film.editions.create!(media_file: file)
    end
  end

  def collection(title, *titles, kind: "tmdb")
    Collection.create!(household: household, kind: kind, title: title).tap do |made|
      titles.each_with_index { |item, index| made.collection_items.create!(item: item, position: index) }
    end
  end

  describe "a collection with nothing in it the profile may see" do
    let!(:saga) { collection("Alien Collection", movie("Alien", "R")) }
    let!(:bears) { collection("Paddington Collection", movie("Paddington", "PG")) }
    let!(:own) { collection("Empty shelf", kind: "manual") }

    it "isn't found by search" do
      get "/api/v1/search", params: { q: "Collection" }, headers: headers
      expect(json["collections"].pluck("title")).to eq([ "Paddington Collection" ])
    end

    it "has no page" do
      get "/api/v1/collections/#{saga.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      get "/api/v1/collections/#{bears.id}", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "lists as it did: TMDB's only with something in them, a household's own always" do
      get "/api/v1/collections", headers: headers
      expect(json.pluck("title")).to contain_exactly("Paddington Collection", "Empty shelf")
    end

    it "can still be edited by an admin watching as anyone" do
      patch "/api/v1/collections/#{saga.id}", params: { title: "Alien films" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  describe "subscribing" do
    let!(:channel) { Channel.create!(household: household, library: tube, folder: "Late", title: "Late night") }

    it "refuses a channel the profile can't see, but always lets it leave one" do
      post "/api/v1/channels/#{channel.id}/subscription", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(ChannelSubscription.count).to eq(0)

      ChannelSubscription.create!(profile: kid, channel: channel)
      delete "/api/v1/channels/#{channel.id}/subscription", headers: headers
      expect(response).to have_http_status(:ok)
      expect(ChannelSubscription.count).to eq(0)
    end
  end
end
