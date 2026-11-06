# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Playback::ShareSpeed do
  include ActiveSupport::Testing::TimeHelpers

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    described_class.forget!
  end

  after { described_class.forget! }

  it "knows nothing of a share no run has read from" do
    expect(described_class.read("/media/far")).to be_nil
  end

  it "keeps the first reading, then leans on what was known" do
    described_class.record("/media/far", 6_000_000.0)
    expect(described_class.read("/media/far")).to eq(6_000_000.0)
    described_class.record("/media/far", 16_000_000.0)
    expect(described_class.read("/media/far")).to be_within(1).of(9_000_000.0)
    expect(described_class.read("/media/near")).to be_nil
  end

  it "lets a floor raise a reading but never lower it, and keeps the reading alive" do
    described_class.record("/media/far", 2_000_000.0)
    described_class.floor("/media/far", 3_000_000.0)
    expect(described_class.read("/media/far")).to eq(3_000_000.0)

    travel_to(6.days.from_now) { described_class.floor("/media/far", 1_000_000.0) }
    expect(described_class.read("/media/far")).to eq(3_000_000.0)
    described_class.forget!
    travel_to(12.days.from_now) { expect(described_class.read("/media/far")).to eq(3_000_000.0) }
  end

  it "takes a floor as the first reading of a share only remote runs read from" do
    described_class.floor("/media/far", 3_000_000.0)
    expect(described_class.read("/media/far")).to eq(3_000_000.0)
  end

  it "ignores a reading that isn't one" do
    described_class.record("/media/far", 0.0)
    described_class.record("/media/far", Float::INFINITY)
    expect(described_class.read("/media/far")).to be_nil
  end
end
