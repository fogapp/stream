# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NtfyClient do
  def with_ntfy(url: "http://ntfy.test", topic: "family")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("NTFY_URL").and_return(url)
    allow(ENV).to receive(:[]).with("NTFY_TOPIC").and_return(topic)
  end

  it "publishes the push as JSON to the relay's root" do
    with_ntfy
    stub = stub_request(:post, "http://ntfy.test/")
      .with(body: { topic: "family", title: "Stream: want_fulfilled", message: "Piranesi is on your shelf" }.to_json)
      .to_return(status: 200, body: "{}")

    Notifier.push_ntfy(title: "Piranesi is on your shelf", kind: "want_fulfilled")

    expect(stub).to have_been_requested
    expect(ActivityEntry.where(event: "push.failed")).to be_empty
  end

  it "records a refusal instead of counting it as delivered" do
    with_ntfy
    stub_request(:post, "http://ntfy.test/").to_return(status: 403, body: '{"error":"forbidden"}')

    Notifier.push_ntfy(title: "T", kind: "want_fulfilled")

    entry = ActivityEntry.find_by(event: "push.failed")
    expect(entry.severity).to eq("warn")
    expect(entry.summary).to include("ntfy rejected our credentials", "forbidden")
  end

  it "does nothing without NTFY_URL" do
    with_ntfy(url: nil)
    Notifier.push_ntfy(title: "T", kind: "want_fulfilled")
    expect(a_request(:post, /./)).not_to have_been_made
  end
end
