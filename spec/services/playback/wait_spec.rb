# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Playback::Wait do
  def wait(seconds = 0.03, gone: false, &condition) = described_class.until(seconds, every: 0.005, gone: -> { gone }, &condition)

  it "ends as soon as what it waits for is there" do
    tries = 0
    expect(wait(5.0) { (tries += 1) > 2 }).to eq(described_class::Outcome::Done)
    expect(tries).to eq(3)
  end

  it "gives up when its time is over" do
    expect(wait { false }).to eq(described_class::Outcome::TimedOut)
  end

  it "stops for a client that hung up" do
    expect(wait(5.0, gone: true) { false }).to eq(described_class::Outcome::Abandoned)
  end

  it "takes what's there over a client that has gone" do
    expect(wait(gone: true) { true }).to eq(described_class::Outcome::Done)
  end
end
