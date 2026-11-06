# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Background jobs console", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, role: "admin") }

  def trigger(key)
    post "/api/v1/background_jobs/#{key}/run", headers: auth_headers(user)
  end

  it "lists every managed job with its history" do
    get "/api/v1/background_jobs", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json.map { |j| j["key"] }).to include("prune_operational_data", "produce_backup")
  end

  it "triggers a job and returns the run it created" do
    trigger("prune_operational_data")

    expect(response).to have_http_status(:accepted)
    expect(json["trigger"]).to eq("manual")
    expect(PruneOperationalDataJob).to have_been_enqueued.with(json["id"])
  end

  it "404s an unknown job" do
    trigger("definitely-not")
    expect(response).to have_http_status(:not_found)
  end

  it "refuses a second trigger while the first is unfinished" do
    trigger("prune_operational_data")
    trigger("prune_operational_data")

    expect(response).to have_http_status(:conflict)
    expect(JobRun.where(job_key: "prune_operational_data").count).to eq(1)
  end

  it "stops blocking once a row is presumed orphaned" do
    trigger("prune_operational_data")
    JobRun.sole.update!(created_at: (ManagedJobs::STALE_AFTER + 1.minute).ago)

    trigger("prune_operational_data")

    expect(response).to have_http_status(:accepted)
  end

  # A backup dump is not orphaned at minute sixteen — presuming so would let
  # a duplicate dump queue up behind it.
  it "honors a long job's own stale window" do
    trigger("produce_backup")
    JobRun.sole.update!(created_at: 1.hour.ago, status: "running", started_at: 1.hour.ago)

    trigger("produce_backup")

    expect(response).to have_http_status(:conflict)
  end

  it "is an admin's console: members and kid profiles can neither see nor start a job" do
    member = create_user(household: household)
    get "/api/v1/background_jobs", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
    expect(json["errors"]).to eq([ "Admin access required" ])
    post "/api/v1/background_jobs/produce_backup/run", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)

    kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
    post "/api/v1/background_jobs/produce_backup/run", headers: auth_headers(user).merge(profile_header(kid))
    expect(response).to have_http_status(:forbidden)

    expect(JobRun.count).to eq(0)
    expect(ProduceBackupJob).not_to have_been_enqueued
  end
end
