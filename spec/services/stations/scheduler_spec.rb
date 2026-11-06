# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Stations::Scheduler do
  include RequestHelpers
  let(:household) { create_household }
  let(:library) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:zone) { ActiveSupport::TimeZone["America/New_York"] }
  # A Sunday afternoon.
  let(:now) { zone.parse("2026-09-27 17:10") }

  before { AppSetting.current.update!(time_zone: "America/New_York") }

  def file(minutes, name = SecureRandom.hex(4))
    MediaFile.create!(household: household, library: library, path: "/tv/#{name}.mkv", size: 1000, mtime: Time.current,
      state: "probed", duration_seconds: minutes * 60.0)
  end

  def show(title, episodes:, minutes: 22, seasons: 1, **attributes)
    Show.create!(household: household, library: library, folder: title, title: title, **attributes).tap do |series|
      (1..seasons).each do |number|
        season = series.seasons.create!(season_number: number)
        (1..episodes).each do |episode|
          series.episodes.create!(season: season, season_number: number, episode_number: episode, title: "#{title} #{number}x#{episode}")
            .editions.create!(media_file: file(minutes))
        end
      end
    end
  end

  def movie(title, minutes: 110, **attributes)
    Movie.create!(household: household, library: library, title: title, **attributes).tap do |film|
      film.editions.create!(media_file: file(minutes))
    end
  end

  def youtube(title, videos:, minutes: 12)
    Channel.create!(household: household, library: library, folder: title, title: title).tap do |channel|
      videos.times do |index|
        Video.create!(household: household, library: library, channel: channel, title: "#{title} #{index + 1}", source: "info_json",
          upload_date: Date.new(2020, 1, 1) + index.weeks).editions.create!(media_file: file(minutes))
      end
    end
  end

  def station(number: "4", snap: 0, blocks: [ { layer: "base", source: {}, ordering: "shuffle" } ], **attributes)
    Station.create!(household: household, number: number, name: "Channel #{number}", snap_minutes: snap, **attributes).tap do |created|
      blocks.each_with_index { |block, index| created.station_blocks.create!(block.merge(position: index)) }
    end
  end

  def aired(station) = station.airings.order(:starts_at).to_a
  def codes(airings) = airings.map { |airing| airing.playable.is_a?(Episode) ? airing.playable.title : airing.playable.title }

  it "fills three days back to back from the half hour, so something is already on" do
    show("Seinfeld", episodes: 30)
    channel = station
    described_class.extend!(channel, now: now)

    airings = aired(channel)
    expect(airings.first.starts_at).to eq(zone.parse("2026-09-27 17:00"))
    expect(airings.last.ends_at).to be >= now + 3.days
    airings.each_cons(2) { |before, after| expect(after.starts_at).to eq(before.ends_at) }
    expect(channel.reload.airing_at(now)).to eq(airings.first)
    expect(channel.scheduled_through).to eq(airings.last.ends_at)
  end

  it "doesn't repeat a program inside the channel's window while there are others" do
    show("Seinfeld", episodes: 200)
    channel = station(no_repeat_days: 3)
    described_class.extend!(channel, now: now)
    ids = aired(channel).map(&:playable_id)
    expect(ids.uniq.size).to eq(ids.size)
  end

  it "is the same schedule every time for the same library" do
    show("Seinfeld", episodes: 40)
    first = station(number: "4")
    described_class.extend!(first, now: now)
    plan = aired(first).map { |airing| [ airing.playable_id, airing.starts_at ] }

    first.airings.delete_all
    described_class.extend!(first, now: now)
    expect(aired(first).map { |airing| [ airing.playable_id, airing.starts_at ] }).to eq(plan)
  end

  it "starts programs on the channel's grid" do
    show("Seinfeld", episodes: 30)
    channel = station(snap: 30)
    described_class.extend!(channel, now: now)
    expect(aired(channel).map { |airing| airing.starts_at.in_time_zone(zone).min }.uniq.sort).to eq([ 0, 30 ])
  end

  it "plays a show in order, looping, and a rebuild picks up after what's on" do
    seinfeld = show("Seinfeld", episodes: 3, seasons: 2)
    channel = station(blocks: [ { layer: "base", source: { show_ids: [ seinfeld.id ] }, ordering: "sequential" } ])
    described_class.extend!(channel, now: now)
    expect(codes(aired(channel)).first(8)).to eq([ "Seinfeld 1x1", "Seinfeld 1x2", "Seinfeld 1x3", "Seinfeld 2x1",
      "Seinfeld 2x2", "Seinfeld 2x3", "Seinfeld 1x1", "Seinfeld 1x2" ])

    # Partway through the second episode, the channel is edited.
    described_class.rebuild!(channel, now: now + 30.minutes)
    expect(codes(aired(channel)).first(4)).to eq([ "Seinfeld 1x1", "Seinfeld 1x2", "Seinfeld 1x3", "Seinfeld 2x1" ])
  end

  it "picks up after a gone episode in the order the block airs in, not episode order" do
    show = show("Columbo", episodes: 3)
    first, second, third = show.episodes.order(:episode_number).to_a
    first.update!(air_date: Date.new(1990, 3, 1))
    second.update!(air_date: Date.new(1990, 1, 1))
    third.update!(air_date: Date.new(1990, 2, 1))
    channel = station(blocks: [ { layer: "base", source: { show_ids: [ show.id ] }, ordering: "chronological" } ])
    file = third.editions.first.media_file
    channel.airings.create!(household: household, station_block: channel.station_blocks.first, playable: third, media_file: file,
      series_key: show.id, reason: "test", starts_at: now - 1.hour, ends_at: now - 38.minutes)
    file.update!(state: "missing")

    described_class.extend!(channel, now: now)

    # Aired: 1x2 (January), 1x3 (February, gone now), so 1x1 (March) is next.
    expect(codes(aired(channel).select { |airing| airing.starts_at >= now }).first(2)).to eq([ "Columbo 1x1", "Columbo 1x2" ])
  end

  it "stops a show that has run out when the block doesn't loop" do
    seinfeld = show("Seinfeld", episodes: 2)
    channel = station(blocks: [ { layer: "base", source: { show_ids: [ seinfeld.id ] }, ordering: "sequential", loops: false } ])
    described_class.extend!(channel, now: now)
    expect(codes(aired(channel))).to eq([ "Seinfeld 1x1", "Seinfeld 1x2" ])
  end

  it "keeps an appointment on the dot, ending what comes before it in time, and continues next week" do
    show("Seinfeld", episodes: 300)
    breaking = show("Breaking Bad", episodes: 5, minutes: 47)
    channel = station(blocks: [
      { layer: "base", source: { exclude_show_ids: [ breaking.id ] }, ordering: "shuffle" },
      { layer: "appointment", days: 0b1000000, start_minute: 20 * 60, end_minute: 21 * 60,
        source: { show_ids: [ breaking.id ] }, ordering: "sequential" }
    ])
    described_class.extend!(channel, now: now, through: now + 8.days)

    sundays = aired(channel).select { |airing| airing.playable.is_a?(Episode) && airing.playable.show_id == breaking.id }
    expect(sundays.map { |airing| airing.starts_at.in_time_zone(zone).strftime("%a %H:%M") }).to eq([ "Sun 20:00", "Sun 20:00" ])
    expect(codes(sundays)).to eq([ "Breaking Bad 1x1", "Breaking Bad 1x2" ])
    before = aired(channel).select { |airing| airing.starts_at < sundays.first.starts_at }.last
    expect(before.ends_at).to be <= sundays.first.starts_at
    expect(sundays.first.reason).to eq("Sundays at 8pm · next in order")
  end

  it "rotates shows like syndication, each where it left off" do
    show("Cheers", episodes: 5)
    show("Frasier", episodes: 5)
    channel = station(blocks: [ { layer: "base", source: {}, ordering: "rotate" } ])
    described_class.extend!(channel, now: now, through: now + 2.hours)
    expect(codes(aired(channel)).first(4)).to eq([ "Cheers 1x1", "Frasier 1x1", "Cheers 1x2", "Frasier 1x2" ])
  end

  it "runs marathons of a few in a row" do
    show("Cheers", episodes: 9)
    show("Frasier", episodes: 9)
    channel = station(blocks: [ { layer: "base", source: {}, ordering: "marathon", marathon_length: 3 } ])
    described_class.extend!(channel, now: now, through: now + 4.hours)
    runs = aired(channel).map { |airing| airing.playable.show.title }.chunk_while { |a, b| a == b }.map(&:size)
    expect(runs.first(3)).to all(eq(3))
  end

  it "lets a special take over for its dates and a daypart for its hours" do
    show("Seinfeld", episodes: 100)
    show("Rudolph", episodes: 20, keywords: [ "christmas" ])
    show("Rugrats", episodes: 50, genres: [ "Kids" ])
    channel = station(blocks: [
      { layer: "base", source: { exclude_keywords: [ "christmas" ], exclude_genres: [ "Kids" ] }, ordering: "shuffle" },
      { layer: "daypart", start_minute: 7 * 60, end_minute: 10 * 60, source: { genres: [ "Kids" ] }, ordering: "shuffle" },
      { layer: "special", starts_on: "2026-09-29", ends_on: "2026-09-29", start_minute: 0, end_minute: 1440,
        source: { keywords: [ "christmas" ] }, ordering: "shuffle" }
    ])
    described_class.extend!(channel, now: now)

    local = ->(airing) { airing.starts_at.in_time_zone(zone) }
    tuesday = aired(channel).select { |airing| local.call(airing).to_date == Date.new(2026, 9, 29) && local.call(airing).hour.positive? }
    expect(tuesday.map { |airing| airing.playable.show.title }.uniq).to eq([ "Rudolph" ])
    monday_morning = aired(channel).select { |airing| local.call(airing).to_date == Date.new(2026, 9, 28) && (8..9).cover?(local.call(airing).hour) }
    expect(monday_morning.map { |airing| airing.playable.show.title }.uniq).to eq([ "Rugrats" ])
    evening = aired(channel).select { |airing| local.call(airing).to_date == Date.new(2026, 9, 28) && local.call(airing).hour >= 12 }
    expect(evening.map { |airing| airing.playable.show.title }.uniq).to eq([ "Seinfeld" ])
  end

  it "gives overlapping layers of one kind to the one listed first" do
    show("Seinfeld", episodes: 100)
    show("Frasier", episodes: 100)
    show("Cheers", episodes: 100)
    channel = station(blocks: [
      { layer: "base", source: {}, ordering: "shuffle" },
      { layer: "daypart", start_minute: 19 * 60, end_minute: 23 * 60, source: { show_ids: [ Show.find_by!(title: "Frasier").id ] }, ordering: "shuffle" },
      { layer: "daypart", start_minute: 18 * 60, end_minute: 1440, source: { show_ids: [ Show.find_by!(title: "Cheers").id ] }, ordering: "shuffle" }
    ])
    described_class.extend!(channel, now: now)

    local = ->(airing) { airing.starts_at.in_time_zone(zone) }
    primetime = aired(channel).select { |airing| local.call(airing).to_date == Date.new(2026, 9, 28) && (20..21).cover?(local.call(airing).hour) }
    expect(primetime.map { |airing| airing.playable.show.title }.uniq).to eq([ "Frasier" ])
  end

  it "chooses shows by network and films by studio" do
    show("The Office", episodes: 3, networks: [ "NBC" ])
    show("The Wire", episodes: 3, networks: [ "HBO" ])
    movie("Heat", studios: [ "Warner Bros." ])
    movie("Mulholland Drive", studios: [ "HBO Films" ])

    nbc = Stations::Source.candidates(household.id, { "networks" => [ "NBC" ] })
    expect(nbc.map(&:series_title).uniq).to eq([ "The Office" ])
    hbo = Stations::Source.candidates(household.id, { "networks" => [ "HBO" ], "studios" => [ "HBO Films" ] })
    expect(hbo.map(&:series_title).uniq).to contain_exactly("The Wire", "Mulholland Drive")
  end

  # The schedule is the household's: whoever pressed Save, what's hidden from
  # them and what they've watched don't change what a smart collection brings.
  it "fills a block from a smart collection the same whoever saves it" do
    film = movie("Heat", year: 1995)
    other = movie("Thief", year: 1981)
    saver = Profile.create!(household: household, name: "Saver")
    Playback::Progress.mark(saver, film, watched: true)
    ProfileExclusion.create!(profile: saver, excludable: other)
    smart = Collection.create!(household: household, kind: "smart", title: "Unwatched",
      rules: Viewing::SmartCollection.normalize({ "type" => "movie", "unwatched" => true }))

    picked = Current.set(profile: saver) do
      Stations::Source.candidates(household.id, { "kinds" => [ "movie" ], "collection_ids" => [ smart.id ] }).map(&:playable_id)
    end

    expect(picked).to contain_exactly(film.id, other.id)
  end

  it "fills the gap before the next half hour with the library's trailers, when the channel says so" do
    show("Seinfeld", episodes: 30, minutes: 22)
    film = movie("Heat")
    %w[a b c d].each_with_index do |name, index|
      Extra.create!(household: household, owner: film, kind: "trailer", title: "Trailer #{name}", media_file: file(1.5 + (index * 0.25), "trailer-#{name}"))
    end
    channel = station(snap: 30, filler: "extras", blocks: [ { layer: "base", source: { kinds: [ "episode" ] }, ordering: "shuffle" } ])
    described_class.extend!(channel, now: now, through: now + 2.hours)

    airings = aired(channel)
    programs = airings.reject(&:filler)
    expect(programs.map { |airing| airing.starts_at.in_time_zone(zone).min }.uniq.sort).to eq([ 0, 30 ])
    filler = airings.select(&:filler)
    expect(filler).not_to be_empty
    expect(filler.map(&:playable_type).uniq).to eq([ "Extra" ])
    expect(filler).to all(have_attributes(reason: "Between programs", station_block_id: nil))
    # Back to back from the end of a program, never past the next one.
    first_gap = filler.select { |airing| airing.starts_at >= programs.first.ends_at && airing.ends_at <= programs.second.starts_at }
    expect(first_gap.first.starts_at).to eq(programs.first.ends_at)
    # Nothing shorter than the shortest trailer is left over.
    expect(first_gap.last.ends_at).to be > programs.second.starts_at - 90.seconds
  end

  it "breaks a program at its chapters on a channel that takes breaks, spending the spare time in the middle" do
    film = movie("Heat")
    3.times { |index| Extra.create!(household: household, owner: film, kind: "trailer", title: "Trailer #{index}", media_file: file(0.5, "t#{index}")) }
    seinfeld = show("Seinfeld", episodes: 3, minutes: 22)
    seinfeld.episodes.each do |episode|
      episode.media_files.first.update!(chapters: [ { "start" => 0.0, "end" => 90.0 }, { "start" => 90.0, "end" => 600.0 },
        { "start" => 600.0, "end" => 1320.0 } ])
    end
    channel = station(snap: 30, filler: "extras", breaks: true, blocks: [ { layer: "base", source: { kinds: [ "episode" ] }, ordering: "sequential" } ])
    described_class.extend!(channel, now: now, through: now + 30.minutes)

    programs = aired(channel).reject(&:filler)
    first = programs.first(3)
    expect(first.map { |part| [ part.media_start, part.media_end ] }).to eq([ [ 0.0, 90.0 ], [ 90.0, 600.0 ], [ 600.0, nil ] ])
    expect(first.map(&:playable_id).uniq.size).to eq(1)
    # Eight spare minutes, split three ways: two breaks and one at the end.
    expect(first.second.starts_at - first.first.ends_at).to be_within(1).of(160)
    expect(first.last.ends_at).to be_within(1).of(zone.parse("2026-09-27 17:30") - 160)
    expect(aired(channel).select(&:filler).map(&:starts_at).min).to eq(first.first.ends_at)
    expect(first.last.parts).to eq(first)
  end

  it "says why when nothing matches" do
    channel = station(blocks: [ { layer: "base", source: { genres: [ "Western" ] }, ordering: "shuffle" } ])
    described_class.extend!(channel, now: now)
    expect(channel.reload.last_error).to eq("Nothing in the library matches “The channel's mix”")
    expect(channel.airings).to be_empty
  end

  it "airs YouTube channels as programs, each channel a series in upload order" do
    show("Seinfeld", episodes: 5)
    tc = youtube("Technology Connections", videos: 4)
    youtube("Hydraulic Press Channel", videos: 3)
    channel = station(blocks: [ { layer: "base", source: { kinds: [ "video" ], channel_ids: [ tc.id ] }, ordering: "sequential" } ])
    described_class.extend!(channel, now: now, through: now + 50.minutes)

    airings = aired(channel)
    expect(airings.map(&:playable_type).uniq).to eq([ "Video" ])
    expect(codes(airings).first(4)).to eq((1..4).map { |index| "Technology Connections #{index}" })
    expect(airings.first).to have_attributes(series_key: tc.id, filler: false, reason: "The channel's mix · next in order")
  end

  it "rotates YouTube channels like shows, and leaves videos out unless a block asks for them" do
    show("Seinfeld", episodes: 5)
    youtube("Technology Connections", videos: 2)
    youtube("Hydraulic Press Channel", videos: 2)
    expect(Stations::Source.candidates(household.id, {}).map(&:playable_type).uniq).to eq([ "Episode" ])

    channel = station(blocks: [ { layer: "base", source: { kinds: %w[video] }, ordering: "rotate" } ])
    described_class.extend!(channel, now: now, through: now + 40.minutes)
    expect(codes(aired(channel)).first(3)).to eq([ "Hydraulic Press Channel 1", "Technology Connections 1", "Hydraulic Press Channel 2" ])
  end

  it "answers only the rules a video can: a picked channel narrows shows away, a genre or unrated-less ceiling leaves videos out" do
    seinfeld = show("Seinfeld", episodes: 2)
    tc = youtube("Technology Connections", videos: 2, minutes: 30)
    mixed = { "kinds" => %w[episode video], "channel_ids" => [ tc.id ] }
    expect(Stations::Source.candidates(household.id, mixed).map(&:series_key).uniq).to eq([ tc.id ])
    expect(Stations::Source.candidates(household.id, mixed.merge("show_ids" => [ seinfeld.id ])).map(&:series_key).uniq)
      .to contain_exactly(tc.id, seinfeld.id)
    expect(Stations::Source.candidates(household.id, mixed.merge("genres" => [ "Comedy" ]))).to be_empty
    expect(Stations::Source.candidates(household.id, mixed.merge("max_rating_age" => 7, "allow_unrated" => false))).to be_empty
    expect(Stations::Source.candidates(household.id, mixed.merge("max_minutes" => 20))).to be_empty
    expect(Stations::Source.candidates(household.id, mixed.merge("year_from" => 2021))).to be_empty
    # Without the video kind picked channels are dropped, rather than narrowing the shows to none.
    expect(Stations::Rules.normalize({ "kinds" => [ "episode" ], "channel_ids" => [ tc.id ] })).not_to have_key("channel_ids")
  end

  it "leaves files that went missing out" do
    seinfeld = show("Seinfeld", episodes: 2)
    seinfeld.episodes.first.media_files.first.update!(state: "missing", missing_since: Time.current)
    expect(Stations::Source.candidates(household.id, {}).map(&:playable_id)).to eq([ seinfeld.episodes.last.id ])
  end
end
