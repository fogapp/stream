# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Stats and profile notifications", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let!(:profile) { Profile.default_for(household) }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:show) { Show.create!(household: household, library: tv, folder: "Severance", title: "Severance") }

  def episode(number)
    season = show.seasons.find_or_create_by!(season_number: 1)
    show.episodes.create!(season: season, season_number: 1, episode_number: number, title: "Episode #{number}").tap do |episode|
      file = MediaFile.create!(household: household, library: tv, path: "/tv/#{number}.mkv", size: 1, mtime: Time.current, state: "probed",
        duration_seconds: 3000, bit_rate: 8_000_000)
      episode.editions.create!(media_file: file)
    end
  end

  describe "new episodes on ntfy" do
    before do
      AppSetting.current.update!(ntfy_url: "http://ntfy.lan")
      AppSetting.bust_cache!
      profile.update!(ntfy_topic: "family-tv")
    end

    it "tells a profile watching the show once, as one message for a batch" do
      first = episode(1)
      first.editions.first.update!(created_at: 1.month.ago)
      Playback::Progress.mark(profile, first, watched: true)
      Profile.create!(household: household, name: "Other", ntfy_topic: "other") # not watching Severance
      episode(2)
      episode(3)
      push = stub_request(:post, "http://ntfy.lan/")
        .with(body: hash_including("topic" => "family-tv", "title" => "New in Severance", "message" => "2 new episodes"))

      NotifyArrivalsJob.perform_now("show", show.id)
      NotifyArrivalsJob.perform_now("show", show.id)

      expect(push).to have_been_requested.once
      expect(WebMock).not_to have_requested(:post, "http://ntfy.lan/").with(body: hash_including("topic" => "other"))
    end

    it "lets a profile choose its topic and send itself a test" do
      patch "/api/v1/notification_preferences", params: { ntfy_topic: "bad topic!" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_content)
      patch "/api/v1/notification_preferences", params: { ntfy_topic: "alex", notify_subscriptions: false }, headers: auth_headers(admin)
      expect(json).to include("ntfy_topic" => "alex", "notify_subscriptions" => false, "ntfy_configured" => true)

      stub_request(:post, "http://ntfy.lan/").with(body: hash_including("topic" => "alex"))
      post "/api/v1/notification_preferences/test", headers: auth_headers(admin)
      expect(json["ok"]).to be(true)
    end
  end

  it "shows what's playing now, the history, and the month in numbers" do
    ep = episode(1)
    PlaybackSession.create!(household: household, profile: profile, playable: ep, media_file: ep.media_files.first, method: "direct",
      decision: { "summary" => "Plays as-is" }, device_name: "Chrome on macOS", started_at: 20.minutes.ago, last_seen_at: 30.seconds.ago,
      position_seconds: 1200)
    PlaybackSession.create!(household: household, profile: profile, playable: ep, media_file: ep.media_files.first, method: "remux",
      decision: {}, device_name: "Safari", started_at: 3.days.ago, last_seen_at: 3.days.ago + 1.hour, state: "ended")

    get "/api/v1/stats/now_playing", headers: auth_headers(admin)
    expect(json.sole).to include("title" => "Severance", "method" => "direct", "summary" => "Plays as-is", "bitrate_kbps" => 8000,
      "progress" => 0.4)

    get "/api/v1/stats/history", headers: auth_headers(admin)
    expect(json.size).to eq(2)

    get "/api/v1/stats/summary", headers: auth_headers(admin)
    expect(json).to include("plays" => 2)
    expect(json["most_watched"].first).to include("title" => "Severance", "plays" => 2)
    expect(json["by_profile"].first["hours"]).to be_within(0.05).of(1.2)

    get "/api/v1/stats/summary", headers: auth_headers(create_user(household: household))
    expect(response).to have_http_status(:forbidden)
  end
end
