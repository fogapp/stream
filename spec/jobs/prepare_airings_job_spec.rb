# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrepareAiringsJob do
  let(:household) { Household.create!(name: "H") }
  let(:library) { create_library(household: household, roots: build_root, kind: "movies", name: "Films") }
  let(:station) { Station.create!(household: household, number: "5", name: "Films") }

  def airing(title, starts_at, keyframes: nil, state: "probed")
    file = MediaFile.create!(household: household, library: library, path: "/films/#{title}.mkv", size: 1, mtime: Time.current, state: state,
      duration_seconds: 3600.0, keyframes: keyframes)
    movie = Movie.create!(household: household, library: library, title: title).tap { |made| made.editions.create!(media_file: file) }
    Airing.create!(household: household, station: station, playable: movie, media_file: file, series_key: movie.id,
      starts_at: starts_at, ends_at: starts_at + 1.hour, reason: "Test")
    file
  end

  it "indexes the files on now and airing in the next few hours that have no keyframe index" do
    on_now = airing("On now", 10.minutes.ago)
    soon = airing("Soon", 2.hours.from_now)
    airing("Indexed", 1.hour.from_now, keyframes: [ 0, 2000 ])
    airing("Tomorrow", 1.day.from_now)
    airing("Over", 3.hours.ago)
    airing("Gone", 1.hour.from_now, state: "missing")

    expect { described_class.perform_now }.to have_enqueued_job(IndexKeyframesJob).exactly(2).times
    expect(IndexKeyframesJob).to have_been_enqueued.with(on_now.id)
    expect(IndexKeyframesJob).to have_been_enqueued.with(soon.id)
  end
end
