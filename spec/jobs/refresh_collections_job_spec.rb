# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe RefreshCollectionsJob do
  let(:household) { Household.create!(name: "H") }

  def collection(title, refreshed_at:, parts: 0)
    Collection.create!(household: household, kind: "tmdb", tmdb_id: rand(1..999_999), title: title, metadata_refreshed_at: refreshed_at).tap do |row|
      parts.times { |index| CollectionPart.create!(household: household, collection: row, tmdb_id: index + 1, title: "#{title} #{index}") }
    end
  end

  it "refreshes collections without their series, and stale ones, but leaves fresh and hand-made ones" do
    unlisted = collection("Unlisted", refreshed_at: 1.day.ago)
    stale = collection("Stale", refreshed_at: 40.days.ago, parts: 2)
    collection("Fresh", refreshed_at: 1.day.ago, parts: 2)
    Collection.create!(household: household, kind: "manual", title: "Friday nights")

    expect { described_class.perform_now }.to have_enqueued_job(SyncCollectionJob).exactly(2).times
    expect(SyncCollectionJob).to have_been_enqueued.with(unlisted.id)
    expect(SyncCollectionJob).to have_been_enqueued.with(stale.id)
  end
end
