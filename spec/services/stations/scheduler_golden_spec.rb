# typed: false
# frozen_string_literal: true

require "rails_helper"

# The scheduler is deterministic (the same rules, library and history give
# the same schedule), so a week of every ordering, layer, break and filler
# it knows is pinned here airing for airing. Ids are fixed so a shuffle's
# seed and its sort are the same on every run. A change that means to
# change what airs regenerates the snapshot: GOLDEN_WRITE=1.
RSpec.describe Stations::Scheduler do
  include RequestHelpers

  SNAPSHOT = Rails.root.join("spec/fixtures/files/scheduler_golden.txt")

  let(:zone) { ActiveSupport::TimeZone["America/New_York"] }
  let(:now) { zone.parse("2026-09-27 17:10") }

  before do
    AppSetting.current.update!(time_zone: "America/New_York")
    @next_id = 0
  end

  def uid(prefix)
    @next_id += 1
    format("%08x-0000-4000-8000-%012d", prefix, @next_id)
  end

  def build_library
    @household = Household.create!(id: uid(1), name: "Golden")
    @library = create_library(household: @household, roots: build_root, kind: "shows", name: "TV")
    @shows = {}
    @movies = {}
  end

  def file(minutes, chapters: [])
    MediaFile.create!(id: uid(2), household: @household, library: @library, path: "/tv/#{@next_id}.mkv", size: 1000 + @next_id,
      mtime: Time.current, state: "probed", duration_seconds: minutes * 60.0, chapters: chapters)
  end

  def show(title, episodes:, minutes: 22, seasons: 1, **attributes)
    @shows[title] = Show.create!(id: uid(3), household: @household, library: @library, folder: title, title: title, **attributes).tap do |series|
      (1..seasons).each do |number|
        season = series.seasons.create!(season_number: number)
        (1..episodes).each do |episode|
          chapters = episode.even? ? [ { "start" => 0.0 }, { "start" => 300.0 }, { "start" => 700.0 }, { "start" => 1000.0 } ] : []
          series.episodes.create!(id: uid(4), season: season, season_number: number, episode_number: episode,
            title: "#{title} #{number}x#{episode}", air_date: Date.new(1990 + number, 1, 1) + (episode * 3).days)
            .editions.create!(media_file: file(minutes + (episode % 3), chapters: chapters))
        end
      end
    end
  end

  def movie(title, minutes:, year:, **attributes)
    @movies[title] = Movie.create!(id: uid(5), household: @household, library: @library, title: title, year: year, **attributes).tap do |film|
      film.editions.create!(media_file: file(minutes))
    end
  end

  def channel_videos(title, videos:, minutes:)
    Channel.create!(id: uid(6), household: @household, library: @library, folder: title, title: title).tap do |channel|
      videos.times do |index|
        Video.create!(id: uid(7), household: @household, library: @library, channel: channel, title: "#{title} #{index + 1}",
          source: "info_json", upload_date: Date.new(2020, 1, 1) + index.weeks).editions.create!(media_file: file(minutes + (index % 4)))
      end
    end
  end

  def station(number, blocks:, **attributes)
    Station.create!(id: uid(8), household: @household, number: number, name: "Channel #{number}", **attributes).tap do |created|
      blocks.each_with_index { |block, index| created.station_blocks.create!(id: uid(9), **block, position: index) }
    end
  end

  def snapshot(station)
    station.airings.reload.order(:starts_at, :media_start).includes(:playable).map do |airing|
      offset = ((airing.starts_at - now) / 60.0).round(2)
      length = ((airing.ends_at - airing.starts_at) / 60.0).round(2)
      [ station.number, offset, length, airing.playable&.title, airing.reason, airing.filler ? "filler" : "",
        airing.media_start&.round(1), airing.media_end&.round(1) ].join(" | ")
    end
  end

  it "plans the same week, airing for airing, for every ordering, layer, break and filler" do
    build_library
    show("Seinfeld", episodes: 24, minutes: 22)
    show("Frasier", episodes: 12, minutes: 23, seasons: 2)
    show("Cheers", episodes: 9, minutes: 24)
    show("Lost", episodes: 8, minutes: 43, seasons: 2)
    show("Christmas Specials", episodes: 4, minutes: 25, keywords: [ "christmas" ])
    movie("Heat", minutes: 170, year: 1995)
    movie("Alien", minutes: 117, year: 1979)
    movie("Aliens", minutes: 137, year: 1986)
    movie("Ronin", minutes: 122, year: 1998)
    movie("Thief", minutes: 123, year: 1981)
    movie("Collateral", minutes: 120, year: 2004)
    filler = channel_videos("Shorts", videos: 15, minutes: 2)
    channel_videos("Talks", videos: 10, minutes: 14)

    sitcoms = [ @shows["Seinfeld"].id, @shows["Frasier"].id, @shows["Cheers"].id ]
    stations = [
      station("2", snap_minutes: 30, breaks: true, filler: "videos", filler_channel_ids: [ filler.id ], blocks: [
        { layer: "base", source: { show_ids: sitcoms }, ordering: "shuffle" }
      ]),
      station("3", snap_minutes: 0, blocks: [
        { layer: "base", source: { show_ids: [ @shows["Seinfeld"].id ] }, ordering: "sequential" },
        { layer: "daypart", source: { show_ids: [ @shows["Lost"].id ] }, ordering: "chronological", start_minute: 21 * 60, end_minute: 23 * 60,
          loops: false }
      ]),
      station("4", snap_minutes: 30, breaks: true, filler: "videos", filler_channel_ids: [ filler.id ], blocks: [
        { layer: "base", source: { show_ids: sitcoms + [ @shows["Lost"].id ] }, ordering: "rotate" },
        { layer: "appointment", days: 0b1000001, start_minute: 20 * 60, end_minute: 21 * 60, source: { show_ids: [ @shows["Cheers"].id ] },
          ordering: "sequential" }
      ]),
      station("5", snap_minutes: 15, no_repeat_days: 1, blocks: [
        { layer: "base", source: { show_ids: sitcoms }, ordering: "marathon", marathon_length: 3 },
        { layer: "daypart", source: { kinds: [ "movie" ] }, ordering: "chronological", start_minute: 19 * 60, end_minute: 23 * 60 }
      ]),
      station("6", snap_minutes: 30, blocks: [
        { layer: "base", source: { kinds: [ "movie" ] }, ordering: "shuffle" },
        { layer: "special", source: { show_ids: [ @shows["Christmas Specials"].id ] }, ordering: "sequential",
          starts_on: Date.new(2026, 9, 29), ends_on: Date.new(2026, 9, 30), start_minute: 18 * 60, end_minute: 20 * 60 + 30 }
      ]),
      station("7", snap_minutes: 0, filler: "videos", filler_channel_ids: [ filler.id ], blocks: [
        { layer: "base", source: { kinds: [ "video" ] }, ordering: "marathon", marathon_length: 2 },
        { layer: "base", source: { kinds: %w[movie episode] }, ordering: "rotate" }
      ])
    ]

    lines = stations.flat_map do |made|
      # Two days, then the rest of the week appended from that history,
      # then rebuilt after an edit from a day in.
      described_class.extend!(made, now: now, through: now + 2.days)
      described_class.extend!(made.reload, now: now + 1.day, through: now + 7.days)
      first = snapshot(made)
      described_class.rebuild!(made.reload, now: now + 1.day)
      first + [ "-- rebuilt --" ] + snapshot(made)
    end

    if ENV["GOLDEN_WRITE"]
      File.write(SNAPSHOT, lines.join("\n") + "\n")
      skip "snapshot written"
    end
    expect(lines.size).to be > 500
    expect(lines.join("\n") + "\n").to eq(File.read(SNAPSHOT))
  end
end
