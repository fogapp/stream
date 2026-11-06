# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe HoldHeavyWhileWatchingJob do
  # The queue tables live in a separate database in production and aren't
  # part of the test schema; Postgres DDL is transactional, so this leaves
  # no trace behind.
  before do
    allow(described_class).to receive(:holding?).and_call_original
    ActiveRecord::Base.connection.create_table :solid_queue_pauses do |t|
      t.string :queue_name, null: false
      t.datetime :created_at, null: false
    end
  end

  let(:household) { Household.create!(name: "H") }
  let(:library) { create_library(household: household, roots: build_root, kind: "movies", name: "Films") }
  let(:movie) do
    file = MediaFile.create!(household: household, library: library, path: "/films/A.mkv", size: 1, mtime: Time.current, state: "probed")
    Movie.create!(household: household, library: library, title: "A").tap { |made| made.editions.create!(media_file: file) }
  end
  let(:heavy) { SolidQueue::Queue.find_by_name("heavy") }

  def session(last_seen_at: Time.current, standby: false, state: "active")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie,
      media_file: movie.media_files.first, method: "remux", decision: {}, started_at: 10.minutes.ago,
      last_seen_at: last_seen_at, standby: standby, state: state)
  end

  it "pauses the heavy queue while someone is watching" do
    session

    described_class.perform_now

    expect(heavy).to be_paused
  end

  it "resumes it once nobody is" do
    heavy.pause
    session(last_seen_at: 5.minutes.ago)
    session(state: "ended")
    session(standby: true)

    described_class.perform_now

    expect(heavy).not_to be_paused
  end

  it "is the hold a running read asks" do
    expect(described_class.holding?).to be(false)
    heavy.pause
    expect(described_class.hold.call).to be(true)
  end

  # A job runs with the query cache on, and a held read writes nothing that
  # would clear it: the pause has to be read afresh every time, or a hold
  # lifted by another process is never seen (Lucid, 2026-10-21/22: both
  # heavy threads held for 12 h, until a deploy killed them).
  it "sees a pause lifted elsewhere while the query cache is on" do
    heavy.pause

    SolidQueue::Pause.cache do
      expect(described_class.holding?).to be(true)
      SolidQueue::Pause.connection.raw_connection.exec("DELETE FROM solid_queue_pauses")
      expect(described_class.holding?).to be(false)
    end
  end

  it "leaves a pause in place while still watched" do
    heavy.pause
    session

    expect { described_class.perform_now }.not_to(change { SolidQueue::Pause.pluck(:id) })
  end
end
