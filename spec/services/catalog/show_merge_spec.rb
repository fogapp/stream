# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Catalog::ShowMerge do
  let(:household) { Household.create!(name: "Merge") }
  let(:root) { build_root }
  let(:tv) { create_library(household: household, roots: root, kind: "shows", name: "TV") }
  let(:profile) { Profile.default_for(household) }

  def probed_file(relative)
    file = MediaFile.create!(household: household, library: tv, path: File.join(root, relative), size: 1,
      mtime: Time.current, state: "probed")
    file.media_streams.create!(index: 0, kind: "video", codec: "h264", width: 1920, height: 1080)
    file
  end

  def show_in(folder, episodes)
    show = Show.create!(household: household, library: tv, folder: folder, title: "Bluey", tmdb_id: 82_728)
    episodes.each do |season_number, number|
      season = show.seasons.find_or_create_by!(season_number: season_number)
      episode = show.episodes.create!(season: season, season_number: season_number, episode_number: number)
      episode.editions.create!(media_file: probed_file("#{folder}/S#{season_number}E#{number}.mkv"))
    end
    show
  end

  def stub_bluey
    configure_tmdb(household)
    stub_tmdb("/search/tv", { "results" => [ { "id" => 82_728, "name" => "Bluey", "first_air_date" => "2018-10-01" } ] })
    stub_tmdb("/tv/82728", tmdb_show(id: 82_728, name: "Bluey", date: "2018-10-01"))
    stub_tmdb("/tv/82728/season/1", tmdb_season(1, { 1 => "Magic Xylophone", 2 => "Hospital" }))
  end

  def match(relative) = Catalog::FileMatcher.new(probed_file(relative)).call

  it "files a second folder of a matched show under the show that already has it" do
    stub_bluey
    match("Bluey/Season 1/Bluey - S01E01.mkv")
    match("Bluey (2018)/Season 1/bluey.2018.s01e01.1080p.mkv")
    match("Bluey (2018)/Season 1/bluey.2018.s01e02.1080p.mkv")

    show = Show.sole
    expect(show).to have_attributes(folder: "Bluey", tmdb_id: 82_728, match_state: "matched")
    expect(show.folders.map(&:folder)).to eq([ "Bluey", "Bluey (2018)" ])
    expect(show.episodes.map { |episode| [ episode.code, episode.editions.count ] }).to eq([ [ "S01E01", 2 ], [ "S01E02", 1 ] ])
  end

  it "brings what anyone did with either copy to the survivor" do
    kept = show_in("Bluey", [ [ 1, 1 ] ])
    gone = show_in("Bluey (2018)", [ [ 1, 1 ], [ 2, 1 ] ])
    kept_episode = kept.episodes.sole
    gone_episode = gone.episodes.find_by!(season_number: 1)
    WatchState.create!(profile: profile, playable: kept_episode, position_seconds: 300, duration_seconds: 600,
      last_watched_at: 1.day.ago, play_count: 1)
    WatchState.create!(profile: profile, playable: gone_episode, position_seconds: 600, duration_seconds: 600,
      completed_at: 2.hours.ago, last_watched_at: 2.hours.ago, play_count: 1)
    Rating.create!(profile: profile, rateable: kept, value: 8, rated_at: 1.day.ago)
    Rating.create!(profile: profile, rateable: gone, value: 3, rated_at: 1.day.ago)
    playlist = Playlist.create!(household: household, profile: profile, title: "Bedtime")
    playlist.playlist_items.create!(item: gone_episode, position: 0)
    block = Station.create!(household: household, number: "9", name: "Bluey").station_blocks
      .create!(layer: "base", source: { "show_ids" => [ gone.id ] }, ordering: "sequential")

    described_class.call(gone, kept)

    expect(Show.all).to eq([ kept ])
    expect(kept.folders.map(&:folder)).to eq([ "Bluey", "Bluey (2018)" ])
    expect(kept.episodes.map(&:code)).to eq(%w[S01E01 S02E01])
    expect(kept_episode.editions.count).to eq(2)
    expect(WatchState.sole).to have_attributes(playable_id: kept_episode.id, position_seconds: 600, play_count: 2)
    expect(WatchState.sole.completed_at).to be_present
    expect(Rating.sole).to have_attributes(rateable_id: kept.id, value: 8)
    expect(PlaylistItem.sole.item_id).to eq(kept_episode.id)
    expect(block.reload.source["show_ids"]).to eq([ kept.id ])
  end

  # Every episode both copies hold, with something of everyone's on each:
  # the same survivor rows however many there are, and the references
  # re-pointed a table at a time, not an episode at a time.
  def shared(count)
    kept = show_in("Bluey #{count}", (1..count).map { |n| [ 1, n ] })
    gone = show_in("Bluey (2018) #{count}", (1..count).map { |n| [ 1, n ] } + [ [ 2, 1 ] ])
    profile
    other = Profile.find_by(household: household, name: "Bingo") || Profile.create!(household: household, name: "Bingo", position: 1)
    playlist = Playlist.create!(household: household, profile: profile, title: "Bedtime")
    station = Station.create!(household: household, number: "9#{count}", name: "Bluey #{count}")
    kept.episodes.each do |episode|
      Rating.create!(profile: profile, rateable: episode, value: 8, rated_at: 1.day.ago)
      Artwork.create!(owner: episode, kind: "still", source: "tmdb", source_ref: "kept-#{episode.id}")
    end
    gone.episodes.where(season_number: 1).each_with_index do |episode, index|
      Rating.create!(profile: profile, rateable: episode, value: 3, rated_at: 1.day.ago)
      Rating.create!(profile: other, rateable: episode, value: 5, rated_at: 1.day.ago)
      Artwork.create!(owner: episode, kind: "still", source: "tmdb", source_ref: "gone-#{episode.id}")
      Artwork.create!(owner: episode, kind: "thumb", source: "tmdb", source_ref: "gone-thumb-#{episode.id}")
      playlist.playlist_items.create!(item: episode, position: index)
      Airing.create!(household: household, station: station, playable: episode, series_key: gone.id, reason: "Test",
        starts_at: Time.current + index.hours, ends_at: Time.current + index.hours + 20.minutes)
    end
    [ kept, gone, other ]
  end

  def survivors(kept, other)
    kept.episodes.reload.map do |episode|
      [ episode.code, Rating.where(rateable: episode).order(:value).pluck(:profile_id, :value).map { |id, value| [ id == other.id ? "Bingo" : "Bluey", value.to_i ] },
        Artwork.where(owner: episode).order(:kind).pluck(:kind, :source_ref).map { |kind, ref| [ kind, ref.split("-").first ] },
        PlaylistItem.where(item: episode).count, Airing.where(playable: episode).pluck(:series_key).uniq == [ kept.id ] ? 1 : Airing.where(playable: episode).count ]
    end
  end

  it "re-points everyone's rows to the twin episodes, the survivor's winning, in the same statements however many twins" do
    references = /\A(SELECT|UPDATE|DELETE).* "(artworks|collection_items|playlist_items|ratings|profile_tags|profile_exclusions|profile_notices|trailers|extras|airings|playback_sessions|offline_downloads|trakt_changes|activity_entries)"/
    kept, gone, other = shared(2)
    small = count_queries(matching: references) { described_class.call(gone, kept) }
    expect(survivors(kept, other)).to eq([
      [ "S01E01", [ [ "Bingo", 5 ], [ "Bluey", 8 ] ], [ [ "still", "kept" ], [ "thumb", "gone" ] ], 1, 1 ],
      [ "S01E02", [ [ "Bingo", 5 ], [ "Bluey", 8 ] ], [ [ "still", "kept" ], [ "thumb", "gone" ] ], 1, 1 ],
      [ "S02E01", [], [], 0, 0 ]
    ])
    expect(Rating.count).to eq(4)
    expect(Artwork.count).to eq(4)

    Show.destroy_all
    kept, gone, other = shared(7)
    large = count_queries(matching: references) { described_class.call(gone, kept) }
    expect(survivors(kept, other).first(7).map { |row| row.drop(1) }.uniq)
      .to eq([ [ [ [ "Bingo", 5 ], [ "Bluey", 8 ] ], [ [ "still", "kept" ], [ "thumb", "gone" ] ], 1, 1 ] ])
    # Rows that lose to the survivor's are destroyed one by one (their own
    # callbacks), as is each merged episode (its dependents), so only the
    # rest is held flat.
    clash = ->(queries) { queries.grep_v(/\ADELETE FROM "(ratings|artworks)" WHERE "\w+"."id" = |\ADELETE FROM "playlist_items" WHERE "playlist_items"."item_id" = /) }
    shape = ->(queries) { clash.call(queries).map { |sql| sql.gsub(/\$\d+(, \$\d+)*/, "?").gsub(/'[^']*'/, "?").gsub(/(WHEN \? THEN \? ?)+/, "WHEN…") }.tally }
    expect(shape.call(large)).to eq(shape.call(small))
  end

  describe "Not this show" do
    it "files a merged folder on its own again, in Needs match, and no rematch merges it back" do
      stub_bluey
      match("Bluey/Season 1/Bluey - S01E01.mkv")
      match("Bluey (2018)/Season 1/bluey.2018.s01e01.1080p.mkv")
      show = Show.sole

      perform_enqueued_jobs do
        Catalog::ShowSplit.call(show, "Bluey (2018)", by: "Alex", client: Tmdb::Client.for(household, language: "en"))
      end

      split = Show.find_by!(folder: "Bluey (2018)")
      expect(split).to have_attributes(title: "Bluey", year: 2018, tmdb_id: nil, match_state: "needs_review")
      expect(split.match_reasons).to include("rejected" => [ 82_728 ], "summary" => "Alex said this isn't Bluey.")
      expect(split.folders.map(&:folder)).to eq([ "Bluey (2018)" ])
      expect(split.episodes.flat_map(&:media_files).map(&:path)).to eq([ File.join(root, "Bluey (2018)/Season 1/bluey.2018.s01e01.1080p.mkv") ])
      expect(show.reload.folders.map(&:folder)).to eq([ "Bluey" ])

      perform_enqueued_jobs { RematchLibrariesJob.perform_now(household.id, tv.id) }
      expect(Show.count).to eq(2)
      expect(split.reload.match_state).to eq("needs_review")
    end

    it "sends a show's only folder back to Needs match, keeping the show" do
      show = show_in("Dune", [ [ 1, 1 ] ])

      expect(Catalog::ShowSplit.call(show, "Dune", by: "Alex", client: nil)).to eq(show)
      expect(show.reload).to have_attributes(tmdb_id: nil, match_state: "needs_review")
      expect(show.match_reasons["rejected"]).to eq([ 82_728 ])
    end
  end
end
