# typed: false
# frozen_string_literal: true

require "rails_helper"

# The episode after this one with a file (PlaybackSessionSerializer
# .following_episode), asked of the database: the same answer as walking
# the show's playable episodes in order, for every episode of an awkward
# show — specials, a gap with no file, an unnumbered episode, a new season.
RSpec.describe PlaybackSessionSerializer do
  let(:household) { Household.create!(name: "Next") }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def walked(episode)
    Viewing::NextUp.available(episode.show).to_a.find do |candidate|
      same_kind = episode.season_number.zero? == candidate.season_number.zero?
      later = [ candidate.season_number, candidate.episode_number.to_i ] <=> [ episode.season_number, episode.episode_number.to_i ]
      same_kind && later.to_i.positive?
    end
  end

  it "follows each episode with the one walking the show in order would" do
    show = Show.create!(household: household, library: tv, folder: "Lost", title: "Lost")
    layout = { 0 => [ 1, 2 ], 1 => [ 1, 2, 3, 4, nil ], 2 => [ 1, 2 ], 3 => [ 2 ] }
    layout.each do |season_number, numbers|
      season = show.seasons.create!(season_number: season_number)
      numbers.each_with_index do |number, index|
        episode = show.episodes.create!(season: season, season_number: season_number, episode_number: number,
          air_date: Date.new(2004 + season_number, 1, 1) + index.weeks)
        # S01E03 has no file: it's skipped.
        next if season_number == 1 && number == 3

        file = MediaFile.create!(household: household, library: tv, path: "/tv/#{season_number}-#{index}.mkv", size: 1, mtime: Time.current,
          state: "probed", duration_seconds: 60)
        episode.editions.create!(media_file: file)
      end
    end

    answers = show.episodes.map { |episode| [ episode.code, described_class.following_episode(episode)&.code ] }
    expect(answers).to eq(show.episodes.map { |episode| [ episode.code, walked(episode)&.code ] })
    expect(answers.to_h).to include("S01E02" => "S01E04", "S01E04" => "S02E01", "S00E02" => nil, "S02E02" => "S03E02", "S03E02" => nil)
  end
end
