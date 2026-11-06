# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe IndexKeyframesJob do
  let(:household) { Household.create!(name: "Frames") }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:file) do
    file = MediaFile.create!(household: household, library: library, path: "/x.ts", size: 1, mtime: Time.current, state: "probed", container: "mpegts", duration_seconds: 60)
    file.media_streams.create!(index: 0, kind: "video", codec: "h264", width: 1280, height: 720)
    file
  end

  before { allow(Media::KeyframeIndex).to receive(:scan!) }

  # The semaphore is taken at dispatch and held for hours, and heavy stands
  # still while someone watches: shared, a scan waiting there would keep the
  # very play that paused it waiting too.
  it "keeps a play's scan out from behind one waiting on the heavy queue" do
    waiting = described_class.new(file.id, true).set(queue: :heavy)
    play = described_class.new(file.id, true).set(queue: Media::KeyframeIndex::PLAY_QUEUE)

    expect(play.concurrency_key).not_to eq(waiting.concurrency_key)
    expect(described_class.new(file.id).concurrency_key).to eq(waiting.concurrency_key)
  end

  it "queues a play's scan though a background one is already waiting, and each only once" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

    2.times { Media::KeyframeIndex.scan_later(file) }
    2.times { Media::KeyframeIndex.scan_later(file, urgent: true) }

    expect(enqueued_jobs.map { |job| job["queue_name"] }).to contain_exactly("heavy", "index")
  end

  # Two whole reads of one file on the two heavy threads is what the one
  # read over a file was built to end.
  it "waits for the one read over the file rather than reading beside it" do
    allow(Media::OnePass).to receive(:exclusively).and_return(nil)

    described_class.set(queue: :heavy).perform_now(file.id, true)

    expect(Media::KeyframeIndex).not_to have_received(:scan!)
    expect(enqueued_jobs.sole).to include("job_class" => "IndexKeyframesJob", "queue_name" => "heavy")
  end

  # That read stands still while someone watches, and this someone is
  # waiting on this scan.
  it "never makes a play's own scan wait for it" do
    allow(Media::OnePass).to receive(:exclusively).and_return(nil)

    described_class.set(queue: :index).perform_now(file.id, true)

    expect(Media::KeyframeIndex).to have_received(:scan!).with(file, hold: nil)
  end
end
