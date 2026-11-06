# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Activity", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }

  before do
    Activity.record(source: "search", event: "plan.completed", summary: "Searched fine",
      duration_ms: 42, household_id: household.id)
    Activity.record(source: "search", event: "plan.failed", summary: "Boom",
      severity: Activity::Severity::Error, household_id: household.id)
    Activity.record(source: "system", event: "boot", summary: "Global entry")
  end

  it "lists household and global entries" do
    get "/api/v1/events", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(json.length).to eq(3)
    expect(json.first.keys).to include("id", "source", "event", "severity", "summary",
      "duration_ms", "trace_id", "created_at", "subject")
  end

  it "names what an entry is about, with a console path to open it" do
    Activity.record(source: "auth", event: "user.invited", summary: "Invited",
      severity: Activity::Severity::Error, subject: user, household_id: household.id)

    get "/api/v1/events", params: { severity: "error" }, headers: auth_headers(user)
    entry = json.find { |e| e["event"] == "user.invited" }
    expect(entry["subject"]).to eq("type" => "User", "id" => user.id, "label" => user.name,
      "path" => "/settings?tab=users")
  end

  it "keeps the pointer when the subject is gone" do
    other = create_user(household: household)
    Activity.record(source: "auth", event: "user.removed", summary: "Removed",
      severity: Activity::Severity::Error, subject: other, household_id: household.id)
    other.delete

    get "/api/v1/events", params: { severity: "error" }, headers: auth_headers(user)
    entry = json.find { |e| e["event"] == "user.removed" }
    expect(entry["subject"]).to eq("type" => "User", "id" => other.id, "label" => nil, "path" => nil)
  end

  it "filters by severity" do
    get "/api/v1/events", params: { severity: "info" }, headers: auth_headers(user)
    expect(json.map { |e| e["event"] }).to contain_exactly("plan.completed", "boot")

    get "/api/v1/events", params: { severity: "error" }, headers: auth_headers(user)
    expect(json.map { |e| e["event"] }).to contain_exactly("plan.failed")
  end

  it "ignores an unknown severity" do
    get "/api/v1/events", params: { severity: "definitely-not" }, headers: auth_headers(user)
    expect(json.length).to eq(3)
  end

  it "does not leak another household's entries" do
    Activity.record(source: "system", event: "secret", summary: "Elsewhere",
      household_id: create_household.id)
    get "/api/v1/events", headers: auth_headers(user)
    expect(json.map { |e| e["event"] }).not_to include("secret")
  end

  it "is for the grown-ups: a kid profile sees none of it" do
    kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
    get "/api/v1/events", headers: auth_headers(user).merge(profile_header(kid))

    expect(response).to have_http_status(:forbidden)
    expect(json["errors"]).to eq([ "Not from a kid profile" ])
  end
end
