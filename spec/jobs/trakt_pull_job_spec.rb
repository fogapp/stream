# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe TraktPullJob do
  include RequestHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:profile) { Profile.default_for(household) }
  let!(:account) do
    TraktSetting.create!(household: household, client_id: "client-abc", client_secret: "secret-xyz")
    TraktAccount.create!(household: household, profile: profile, state: "linked", access_token: "at-1", refresh_token: "rt-1",
      expires_at: 1.day.from_now)
  end

  before { allow_any_instance_of(Trakt::Api).to receive(:sleep) } # rubocop:disable RSpec/AnyInstance

  def trakt_answers(status, body = { error: "nope" })
    stub_request(:get, "https://api.trakt.tv/sync/last_activities").to_return(status: status, body: body.to_json)
  end

  def pull_failures = ActivityEntry.where(event: "trakt.pull_failed")

  # Every 15 minutes, per account: nothing changed means nothing to look up.
  it "doesn't read the catalogue for an account with nothing new" do
    activities = { "movies" => { "watched_at" => "2026-01-01T00:00:00.000Z" } }
    account.update!(last_activities: activities)
    trakt_answers(200, activities)
    allow(Trakt::Catalog).to receive(:new).and_call_original

    described_class.perform_now(account.id)

    expect(Trakt::Catalog).not_to have_received(:new)
    expect(account.reload.last_error).to be_nil
  end

  it "waits out a rate limit a minute at a time, five times, before calling the sync failed" do
    trakt_answers(429)
    freeze_time

    described_class.perform_now(account.id)
    retry_job = enqueued_jobs.sole
    expect(retry_job["job_class"]).to eq("TraktPullJob")
    # A minute, plus ActiveJob's default jitter — not the seconds a polynomial first retry waits.
    expect(Time.zone.parse(retry_job["scheduled_at"]) - Time.current).to be_between(60, 70)
    expect(account.reload.last_error).to be_nil

    4.times do
      job = ActiveJob::Base.deserialize(enqueued_jobs.pop)
      job.perform_now
    end

    expect(enqueued_jobs).to be_empty
    expect(account.reload.last_error).to include("Couldn't sync with Trakt", "rate limited")
    expect(pull_failures.count).to eq(1)
  end

  it "retries an outage, then says so on the account and in Activity" do
    trakt_answers(503)

    described_class.perform_now(account.id)
    expect(enqueued_jobs.size).to eq(1)
    2.times { ActiveJob::Base.deserialize(enqueued_jobs.pop).perform_now }

    expect(enqueued_jobs).to be_empty
    expect(account.reload.last_error).to start_with("Couldn't sync with Trakt")
    expect(pull_failures.sole.severity).to eq("error")
  end

  it "fails a request Trakt refuses straight away, without retrying it" do
    trakt_answers(400)

    described_class.perform_now(account.id)

    expect(enqueued_jobs).to be_empty
    expect(account.reload.last_error).to start_with("Couldn't sync with Trakt")
    expect(pull_failures.count).to eq(1)
  end

  it "does nothing for an account that has been unlinked" do
    account.update!(state: "pending")

    expect { described_class.perform_now(account.id) }.not_to change(ActivityEntry, :count)
    expect(WebMock).not_to have_requested(:any, /api\.trakt\.tv/)
  end
end
