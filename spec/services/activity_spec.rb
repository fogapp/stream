# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activity do
  it "records entries with the current trace id" do
    Current.trace_id = SecureRandom.uuid
    entry = described_class.record(source: "spec", event: "thing.happened", summary: "hi")
    expect(entry.trace_id).to eq(Current.trace_id)
    expect(entry.severity).to eq("info")
  end

  it "never raises out of record" do
    allow(ActivityEntry).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "the database went away")
    expect(described_class.record(source: "spec", event: "bad", summary: "hi")).to be_nil
  end
end
