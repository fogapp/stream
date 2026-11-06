# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Catalog version", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root) }

  def version
    get "/api/v1/catalog_version", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    json.fetch("version")
  end

  def arrive(title, state: "probed")
    Movie.create!(household: household, library: library, title: title).tap do |movie|
      file = MediaFile.create!(household: household, library: library, path: "/m/#{title}.mkv", size: 1, mtime: Time.current, state: state)
      movie.editions.create!(media_file: file)
    end
  end

  it "moves when a file becomes playable or goes missing, and not otherwise" do
    empty = version
    expect(version).to eq(empty)

    probing = arrive("The Invite", state: "discovered")
    expect(version).to eq(empty)

    probing.editions.first.media_file.update!(state: "probed")
    arrived = version
    expect(arrived).not_to eq(empty)

    probing.editions.first.media_file.update!(state: "missing")
    expect(version).not_to eq(arrived)
  end

  it "doesn't move for another household's arrivals" do
    before = version
    other = create_household(name: "Elsewhere")
    elsewhere = create_library(household: other, roots: build_root)
    movie = Movie.create!(household: other, library: elsewhere, title: "Heat")
    movie.editions.create!(media_file: MediaFile.create!(household: other, library: elsewhere, path: "/o/Heat.mkv",
      size: 1, mtime: Time.current, state: "probed"))
    expect(version).to eq(before)
  end
end
