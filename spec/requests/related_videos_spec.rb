# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Related videos", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }

  def channel(title) = Channel.create!(household: household, library: library, folder: title, title: title)

  def video(channel, title, tags:, description: nil)
    Video.create!(household: household, library: library, channel: channel, title: title, tags: tags, description: description,
      upload_date: Date.new(2024, 1, 1), source: "info_json").tap do |video|
      file = MediaFile.create!(household: household, library: library, path: "/v/#{title}.mkv", size: 1, mtime: Time.current, state: "probed",
        duration_seconds: 600)
      video.editions.create!(media_file: file)
    end
  end

  it "offers other videos about the same things, leaving out what More from the channel already shows" do
    tc = channel("Technology Connections")
    other = channel("Cleaning Science")
    travel = channel("Rivers Everywhere")
    viewing = video(tc, "The dishwasher, revisited", tags: %w[dishwasher appliances detergent],
      description: "Why your dishwasher detergent works better than you think. https://patreon.com/tc")
    video(tc, "Toasters", tags: %w[toaster appliances])
    video(other, "How dishwasher detergent works", tags: %w[dishwasher detergent chemistry],
      description: "Enzymes in detergent, explained.")
    video(travel, "The rivers of Europe", tags: %w[rivers geography travel], description: "Along the Danube.")
    EmbedTitlesJob.perform_now

    get "/api/v1/videos/#{viewing.id}", headers: headers
    expect(json["more_from_channel"].map { |v| v["title"] }).to eq([ "Toasters" ])
    expect(json["related"].map { |v| v["title"] }).to eq([ "How dishwasher detergent works" ])
    expect(json["related"].first["channel"]).to include("title" => "Cleaning Science")
  end

  describe "the end screen" do
    let(:tc) { channel("Technology Connections") }
    let!(:viewing) { video(tc, "The dishwasher, revisited", tags: %w[dishwasher appliances detergent]) }

    it "offers one more from the channel, what this profile hasn't finished first, and others from elsewhere" do
      toasters = video(tc, "Toasters", tags: %w[toaster appliances])
      video(tc, "Kettles", tags: %w[kettle appliances])
      WatchState.create!(profile: Profile.default_for(household), playable: Video.find_by!(title: "Kettles"), completed_at: Time.current)
      video(channel("Cleaning Science"), "How dishwasher detergent works", tags: %w[dishwasher detergent chemistry])
      video(channel("Rivers Everywhere"), "The rivers of Europe", tags: %w[rivers geography travel])
      EmbedTitlesJob.perform_now

      get "/api/v1/videos/#{viewing.id}", headers: headers
      expect(json["end_screen"]["next"]).to include("id" => toasters.id)
      others = json["end_screen"]["others"]
      # The nearest first, then the newest from anywhere else to fill it out.
      expect(others.map { |v| v["title"] }).to eq([ "How dishwasher detergent works", "The rivers of Europe" ])
      expect(others.map { |v| v.dig("channel", "title") }).not_to include("Technology Connections")
    end

    it "is null when Settings › YouTube turns it off" do
      AppSetting.current.update!(youtube_end_screen: false)
      get "/api/v1/videos/#{viewing.id}", headers: headers
      expect(json["end_screen"]).to be_nil
    end
  end

  it "has none for a video not yet worked out" do
    lone = video(channel("Solo"), "Untagged", tags: [])
    get "/api/v1/videos/#{lone.id}", headers: headers
    expect(json["related"]).to eq([])
  end
end
