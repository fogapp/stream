# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "About", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }

  it "returns the running version" do
    get "/api/v1/about", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(json["git_sha"]).to be_present
    expect(json["git_sha_short"]).to eq(json["git_sha"].first(12))
    expect(json["environment"]).to eq("test")
    expect(json["ruby_version"]).to eq(RUBY_VERSION)
    expect(json["rails_version"]).to eq(Rails.version)
    expect(json["postgres_version"]).to match(/\A\d+(\.\d+)?/)
    expect(Time.iso8601(json["booted_at"])).to be_past
  end

  it "describes the machine it runs on" do
    get "/api/v1/about", headers: auth_headers(user)

    machine = json["machine"]
    expect(machine["hostname"]).to be_present
    expect(machine["os"]).to be_present
    expect(machine["arch"]).to be_present
    expect(machine["cpus"]).to be_positive
    expect(machine).to include("memory_total_bytes", "containerized", "pid", "user")

    storage = json["storage"]
    expect(storage["state_dir"]).to eq(Rails.root.join("storage").to_s)
    expect(storage).to include("total_bytes", "free_bytes")
  end

  it "requires authentication" do
    get "/api/v1/about"
    expect(response).to have_http_status(:unauthorized)
  end
end
