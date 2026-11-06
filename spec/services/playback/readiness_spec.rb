# typed: false
# frozen_string_literal: true

require "rails_helper"

# docs/PERF_PROPOSAL.md › P11: a waiting segment request sleeps until the
# transcoder says its session has something new, not a poll every 25 ms.
RSpec.describe Playback::Readiness do
  before do
    allow(described_class).to receive(:listen)
    described_class::STATE[:listening] = true
  end

  after { described_class::STATE[:listening] = false }

  it "wakes a wait the moment its session is announced, and only its session" do
    mark = described_class.generation("s1", 0)
    woke = Queue.new
    waiter = Thread.new do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.wait("s1", 0, mark)
      woke << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end
    sleep 0.02
    described_class.heard("s2:0:4")
    sleep 0.02
    expect(woke).to be_empty
    described_class.heard("s1:0:7")
    waiter.join
    expect(woke.pop).to be < 0.2
  end

  it "doesn't sleep past something announced between the mark and the wait" do
    mark = described_class.generation("s3", 0)
    described_class.heard("s3:0:1")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    described_class.wait("s3", 0, mark)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.05
  end
end
