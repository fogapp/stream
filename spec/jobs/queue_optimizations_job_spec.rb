# typed: false
# frozen_string_literal: true

require "rails_helper"

# What the nightly pass wants soon: the next episode of every show any
# profile is watching, read once for the household, not once a profile.
RSpec.describe QueueOptimizationsJob do
  let(:household) { Household.create!(name: "Soon") }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def show(title, episodes: 3)
    Show.create!(household: household, library: tv, folder: title, title: title).tap do |series|
      season = series.seasons.create!(season_number: 1)
      (1..episodes).each do |number|
        file = MediaFile.create!(household: household, library: tv, path: "/tv/#{title}/#{number}.mkv", size: 1, mtime: Time.current,
          state: "probed", duration_seconds: 1200)
        series.episodes.create!(season: season, season_number: 1, episode_number: number).editions.create!(media_file: file)
      end
    end
  end

  def watched(profile, episode, at: 1.day.ago)
    WatchState.create!(profile: profile, playable: episode, completed_at: at, last_watched_at: at, play_count: 1)
  end

  def wanted(job = described_class.new)
    Current.set(household: household) { job.send(:wanted_soon, household) }
  end

  def file_of(episode) = episode.editions.sole.media_file_id

  it "wants each profile's next episode of what it's watching, now, and nothing it stopped watching" do
    first = Profile.default_for(household)
    second = Profile.create!(household: household, name: "Two", position: 1)
    office = show("Office")
    lost = show("Lost")
    old = show("Old")
    watched(first, office.episodes.find_by(episode_number: 1))
    watched(second, office.episodes.find_by(episode_number: 2))
    watched(second, lost.episodes.find_by(episode_number: 1))
    watched(first, old.episodes.find_by(episode_number: 1), at: 40.days.ago)

    found = wanted
    expect(found.keys).to contain_exactly(file_of(office.episodes.find_by(episode_number: 2)), file_of(office.episodes.find_by(episode_number: 3)),
      file_of(lost.episodes.find_by(episode_number: 2)))
    expect(found.values.map(&:last).uniq).to eq([ OptimizedVersion::Reason::NextUp ])
  end

  it "reads the same number of times however many profiles are watching" do
    Profile.default_for(household)
    profiles = (1..5).map { |n| Profile.create!(household: household, name: "P#{n}", position: n) }
    series = show("Office")
    watched(profiles.first, series.episodes.first)
    small = count_queries { wanted }
    profiles.drop(1).each_with_index { |profile, index| watched(profile, show("More #{index}").episodes.first) }
    large = count_queries { wanted }

    expect(large.size).to eq(small.size), large.join("\n")
    expect(wanted.size).to eq(5)
  end
end
