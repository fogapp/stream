# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebhookJob do
  let(:household) { Household.create!(name: "H") }
  let(:user) { household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword") }
  let(:url) { "http://homeassistant.test:8123/api/webhook/stream" }

  it "does nothing without a webhook URL" do
    described_class.perform_now("episode_added", "Severance S02E01 is ready", "/shows/1")
    expect(a_request(:post, /./)).not_to have_been_made
  end

  it "posts the event as JSON to the configured URL" do
    AppSetting.current.update!(webhook_url: url)
    stub = stub_request(:post, url).with { |request|
      body = JSON.parse(request.body)
      body.slice("event", "title", "path", "app") == { "event" => "episode_added", "title" => "Severance S02E01 is ready",
                                                       "path" => "/shows/1", "app" => "stream" } && body["at"].present?
    }.to_return(status: 200, body: "")

    described_class.perform_now("episode_added", "Severance S02E01 is ready", "/shows/1")

    expect(stub).to have_been_requested
  end

  it "records a warning when the receiver fails, and does not die loudly" do
    AppSetting.current.update!(webhook_url: url)
    stub_request(:post, url).to_return(status: 500, body: "")

    expect { described_class.perform_now("want_needs_review", "Gave up", nil) }.not_to raise_error

    entry = ActivityEntry.find_by(event: "webhook.failed")
    expect(entry.severity).to eq("warn")
    expect(entry.summary).to include("want_needs_review")
    expect(described_class.new.report_death?(UpstreamHttpClient::Error.new("down"))).to be(false)
  end

  it "still reports a crash that is not the receiver's fault" do
    expect(described_class.new.report_death?(NoMethodError.new("boom"))).to be(true)
  end

  describe "fan-out from Notifier" do
    it "enqueues a webhook only when a URL is configured" do
      Notifier.notify(users: [ user ], kind: "episode_added", title: "T", dedupe_key: "k1", path: "/shows/1")
      expect(described_class).not_to have_been_enqueued

      AppSetting.current.update!(webhook_url: url)
      Notifier.notify(users: [ user ], kind: "episode_added", title: "T", dedupe_key: "k2", path: "/shows/1")
      expect(described_class).to have_been_enqueued.with("episode_added", "T", "/shows/1")
    end

    it "does not fire for a deduplicated re-emit" do
      AppSetting.current.update!(webhook_url: url)
      Notifier.notify(users: [ user ], kind: "episode_added", title: "T", dedupe_key: "same", path: nil)
      clear_enqueued_jobs
      Notifier.notify(users: [ user ], kind: "episode_added", title: "T", dedupe_key: "same", path: nil)
      expect(described_class).not_to have_been_enqueued
    end
  end
end
