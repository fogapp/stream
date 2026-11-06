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
    expect(json).to include("webhook_url" => nil, "max_video_transcodes" => nil, "encoder" => "software")
  end

  it "lets an admin set the webhook, and records it" do
    patch "/api/v1/app_setting", params: { webhook_url: " http://ha.lan/hook " }, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    expect(json["webhook_url"]).to eq("http://ha.lan/hook")
    expect(AppSetting.current.webhook_url).to eq("http://ha.lan/hook")
    expect(ActivityEntry.find_by(event: "general.changed")).to be_present
  end

  it "clears the webhook when given a blank" do
    AppSetting.current.update!(webhook_url: "http://ha.lan/hook")
    patch "/api/v1/app_setting", params: { webhook_url: "" }, headers: auth_headers(admin)
    expect(json["webhook_url"]).to be_nil
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

  it "refuses a member" do
    patch "/api/v1/app_setting", params: { webhook_url: "http://x" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end
end
