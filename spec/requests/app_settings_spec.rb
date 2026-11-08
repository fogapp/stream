# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "General settings", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }

  it "shows the settings to any member" do
    get "/api/v1/app_setting", headers: auth_headers(member)
    expect(response).to have_http_status(:ok)
    expect(json).to include("webhook_url_set" => false, "webhook_host" => nil, "max_video_transcodes" => nil, "encoder" => "software")
  end

  # The webhook's path is its secret (Home Assistant's webhook id): written,
  # never read back, kept encrypted, and kept out of Activity.
  it "lets an admin set the webhook, write-only, and records only that it changed" do
    patch "/api/v1/app_setting", params: { webhook_url: " http://ha.lan:8123/api/webhook/s3cret " }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(json).to include("webhook_url_set" => true, "webhook_host" => "ha.lan:8123")
    expect(json).not_to have_key("webhook_url")
    expect(response.body).not_to include("s3cret")
    expect(AppSetting.current.webhook_url).to eq("http://ha.lan:8123/api/webhook/s3cret")

    stored = AppSetting.connection.select_value("SELECT webhook_url FROM app_settings")
    expect(stored).not_to include("s3cret")

    entry = ActivityEntry.find_by(event: "general.changed")
    expect(entry.summary).to include("webhook changed")
    expect(entry.payload).to include("webhook_changed" => true)
    expect(entry.payload.to_json).not_to include("s3cret")

    get "/api/v1/app_setting", headers: auth_headers(member)
    expect(json).to include("webhook_url_set" => true)
    expect(response.body).not_to include("s3cret")
  end

  it "refuses a webhook that isn't a web address" do
    %w[ftp://ha.lan/hook not-a-url http://].each do |url|
      patch "/api/v1/app_setting", params: { webhook_url: url }, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"]).to eq([ "The webhook's address starts with http:// or https://" ])
    end
    expect(AppSetting.current.webhook_url).to be_nil
  end

  it "clears the webhook when given a blank" do
    AppSetting.current.update!(webhook_url: "http://ha.lan/hook")
    patch "/api/v1/app_setting", params: { webhook_url: "" }, headers: auth_headers(admin)
    expect(json).to include("webhook_url_set" => false, "webhook_host" => nil)
    expect(AppSetting.current.webhook_url).to be_nil
  end

  it "leaves the webhook alone when other settings change" do
    AppSetting.current.update!(webhook_url: "http://ha.lan/hook")
    patch "/api/v1/app_setting", params: { max_video_transcodes: 2 }, headers: auth_headers(admin)
    expect(json).to include("webhook_url_set" => true)
    expect(ActivityEntry.find_by(event: "general.changed").payload).to include("webhook_changed" => false)
  end

  it "lists each profile's ntfy topic and what's pushed to it — for an admin only" do
    Profile.default_for(household).update!(ntfy_topic: "stream-family", notify_new_episodes: true, notify_subscriptions: false)
    Profile.create!(household: household, name: "Kids")

    get "/api/v1/app_setting", headers: auth_headers(admin)
    expect(json["ntfy_topics"].map { |row| row.slice("topic", "pushes") }).to eq([
      { "topic" => "stream-family", "pushes" => %w[new_episodes live_reminders] },
      { "topic" => nil, "pushes" => %w[new_episodes new_videos live_reminders] }
    ])

    get "/api/v1/app_setting", headers: auth_headers(member)
    expect(json["ntfy_topics"]).to eq([])
  end

  {
    { ntfy_url: "ntfy.lan" } => "ntfy's address starts with http:// or https://",
    { max_video_transcodes: 9 } => "The limit must be between 1 and 8",
    { optimize_quiet_start_hour: "3.5" } => "Quiet hours run from one hour of the day (0–23) to another",
    { optimize_quiet_end_hour: 24 } => "Quiet hours run from one hour of the day (0–23) to another",
    { optimize_max_height: 480 } => "Optimized versions are 720p, 1080p or 2160p",
    { optimize_budget_gb: 0 } => "The space for optimized versions is between 1 and 100000 GB"
  }.each do |change, message|
    it "refuses #{change.keys.first} out of range, saving nothing" do
      before = AppSetting.current.attributes
      patch "/api/v1/app_setting", params: change, headers: auth_headers(admin)
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"]).to eq([ message ])
      expect(AppSetting.current.reload.attributes).to eq(before)
    end
  end

  it "refuses a member" do
    patch "/api/v1/app_setting", params: { webhook_url: "http://x" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end
end
