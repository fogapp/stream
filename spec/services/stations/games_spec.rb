# typed: false
# frozen_string_literal: true

require "rails_helper"

# A Grid channel's teams' games (PROPOSAL §7.7, §7.8): on the schedule
# whenever one of its clubs plays, over its programming, and kept true to
# the game as it's played.
RSpec.describe Stations::Games do
  include RequestHelpers
  let(:household) { create_household }
  let(:library) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:zone) { ActiveSupport::TimeZone["America/Chicago"] }
  # A Monday afternoon.
  let(:now) { zone.parse("2026-10-19 13:10") }
  let(:schedule) { instance_double(Mlb::Schedule) }
  let(:games) { {} }
  BREWERS = 158
  CUBS = 112
  CARDINALS = 138

  before do
    AppSetting.current.update!(time_zone: "America/Chicago")
    allow(EnsureMlbTeamStreamsJob).to receive(:perform_later)
    MlbSetting.create!(household: household, username: "fan@example.com", password: "secret")
    allow(Mlb::Schedule).to receive(:new).and_return(schedule)
    allow(schedule).to receive(:games) { |date| games.fetch(date, []) }
    show("Seinfeld", episodes: 300)
  end

  def show(title, episodes:, minutes: 22)
    Show.create!(household: household, library: library, folder: title, title: title).tap do |series|
      season = series.seasons.create!(season_number: 1)
      (1..episodes).each do |episode|
        file = MediaFile.create!(household: household, library: library, path: "/tv/#{title}-#{episode}.mkv", size: 1000, mtime: Time.current,
          state: "probed", duration_seconds: minutes * 60.0)
        series.episodes.create!(season: season, season_number: 1, episode_number: episode, title: "#{title} #{episode}")
          .editions.create!(media_file: file)
      end
    end
  end

  TEAMS = { BREWERS => %w[Milwaukee Brewers], CUBS => %w[Chicago Cubs], CARDINALS => [ "St. Louis", "Cardinals" ] }.freeze

  def side(id)
    location, club = TEAMS.fetch(id)
    { "team" => { "id" => id, "name" => "#{location} #{club}", "teamName" => club } }
  end

  # A game on its local date, first pitch at a local time.
  def game(pk, away:, home:, at:, state: "Preview", detailed: "Scheduled", **extra)
    first_pitch = zone.parse(at)
    entry = { "gamePk" => pk, "gameDate" => first_pitch.utc.iso8601, "officialDate" => first_pitch.to_date.iso8601, "gameType" => "R",
              "doubleHeader" => "N", "gameNumber" => 1, "status" => { "abstractGameState" => state, "detailedState" => detailed },
              "teams" => { "away" => side(away), "home" => side(home) } }.merge(extra)
    (games[first_pitch.to_date] ||= []) << entry
    entry
  end

  def station(teams, number: "4")
    Station.create!(household: household, number: number, name: "Channel #{number}", snap_minutes: 30, mlb_team_ids: teams).tap do |made|
      made.station_blocks.create!(layer: "base", source: {}, ordering: "sequential", position: 0)
    end
  end

  def games_on(channel) = channel.airings.where.not(mlb_game_pk: nil).order(:starts_at).to_a

  it "airs a team's game from first pitch back to the quarter hour, for three hours, with the library around it" do
    game(1, away: CUBS, home: BREWERS, at: "2026-10-19 18:40")
    channel = station([ BREWERS ])
    Stations::Scheduler.extend!(channel, now: now)

    airing = games_on(channel).sole
    stream = LiveStream.find_by!(household: household, mlb_team_id: BREWERS)
    expect(airing).to have_attributes(starts_at: zone.parse("2026-10-19 18:30"), ends_at: zone.parse("2026-10-19 21:45"),
      playable: stream, media_file_id: nil, mlb_game_pk: 1, program_title: "Cubs at Brewers", program_subtitle: nil,
      reason: "Milwaukee Brewers baseball", station_block_id: nil)
    expect(stream).to have_attributes(name: "Milwaukee Brewers", kind: "mlb")

    library = channel.airings.where(mlb_game_pk: nil).order(:starts_at).to_a
    before = library.select { |each| each.starts_at < airing.starts_at }
    expect(before.last.ends_at).to be <= airing.starts_at
    expect(library.find { |each| each.starts_at >= airing.ends_at }.starts_at).to eq(zone.parse("2026-10-19 22:00"))
    expect(channel.reload.last_error).to be_nil
  end

  it "plays the broadcast of the team listed first, and when two of its teams play at once, the first one's game" do
    game(1, away: CUBS, home: BREWERS, at: "2026-10-19 18:40")
    game(2, away: CARDINALS, home: CUBS, at: "2026-10-20 19:05")
    game(3, away: BREWERS, home: CARDINALS, at: "2026-10-20 18:45")
    channel = station([ CUBS, BREWERS ])
    Stations::Scheduler.extend!(channel, now: now)

    aired = games_on(channel)
    expect(aired.map(&:mlb_game_pk)).to eq([ 1, 2 ])
    expect(aired.map { |airing| airing.playable.mlb_team_id }).to eq([ CUBS, CUBS ])
  end

  it "leaves out postponed games and games over, and airs a game on now from now" do
    game(1, away: CUBS, home: BREWERS, at: "2026-10-19 12:10", state: "Live", detailed: "In Progress")
    game(2, away: CUBS, home: BREWERS, at: "2026-10-20 18:40", detailed: "Postponed")
    game(3, away: BREWERS, home: CUBS, at: "2026-10-19 09:10", state: "Final", detailed: "Final")
    channel = station([ BREWERS ])
    Stations::Scheduler.extend!(channel, now: now)

    expect(games_on(channel).map { |airing| [ airing.mlb_game_pk, airing.starts_at ] }).to eq([ [ 1, zone.parse("2026-10-19 13:00") ] ])
    expect(channel.airing_at(now).mlb_game_pk).to eq(1)
  end

  it "follows the first game of a doubleheader with the second, which has no time of its own" do
    game(1, away: CUBS, home: BREWERS, at: "2026-10-19 15:10", "doubleHeader" => "Y")
    second = game(2, away: CUBS, home: BREWERS, at: "2026-10-19 15:10", "doubleHeader" => "Y", "gameNumber" => 2)
    second["status"]["startTimeTBD"] = true
    channel = station([ BREWERS ])
    Stations::Scheduler.extend!(channel, now: now)

    expect(games_on(channel).map { |airing| [ airing.starts_at, airing.ends_at, airing.program_subtitle ] }).to eq([
      [ zone.parse("2026-10-19 15:00"), zone.parse("2026-10-19 18:15"), "Game 1 of 2" ],
      [ zone.parse("2026-10-19 18:15"), zone.parse("2026-10-19 21:15"), "Game 2 of 2" ]
    ])
  end

  it "names a playoff game's series" do
    game(1, away: CUBS, home: BREWERS, at: "2026-10-19 18:40", "gameType" => "L", "seriesDescription" => "NL Championship Series",
      "seriesGameNumber" => 3)
    channel = station([ BREWERS ])
    Stations::Scheduler.extend!(channel, now: now)

    expect(games_on(channel).sole.program_subtitle).to eq("NL Championship Series · Game 3")
  end

  it "says why there are no games without an MLB.tv account, and schedules the library anyway" do
    MlbSetting.delete_all
    channel = station([ BREWERS ])
    Stations::Scheduler.extend!(channel, now: now)

    expect(channel.reload.last_error).to eq("Sign in to MLB.tv in Settings › Integrations for its teams' games")
    expect(channel.airings).not_to be_empty
  end

  describe ".follow!" do
    let(:live) { game(1, away: CUBS, home: BREWERS, at: "2026-10-19 18:40", state: "Live", detailed: "In Progress") }

    it "ends a game's slot when the game is over, and schedules what follows from there" do
      live
      channel = station([ BREWERS ])
      Stations::Scheduler.extend!(channel, now: now)
      live.merge!("status" => { "abstractGameState" => "Final", "detailedState" => "Final" })
      over = zone.parse("2026-10-19 21:07")

      expect(described_class.follow!(channel, now: over)).to be(true)
      expect(games_on(channel).sole.ends_at).to eq(over)
      expect(channel.airings.where(mlb_game_pk: nil).where("starts_at >= ?", over).order(:starts_at).first.starts_at)
        .to eq(zone.parse("2026-10-19 21:30"))
      expect(described_class.follow!(channel, now: over + 1.minute)).to be(false)
    end

    it "ends a game's slot when the game is suspended" do
      live
      channel = station([ BREWERS ])
      Stations::Scheduler.extend!(channel, now: now)
      live.merge!("status" => { "abstractGameState" => "Live", "detailedState" => "Suspended: Rain" })
      stopped = zone.parse("2026-10-19 20:02")

      expect(described_class.follow!(channel, now: stopped)).to be(true)
      expect(games_on(channel).sole.ends_at).to eq(stopped)
    end

    it "gives a game still going near its slot's end more time" do
      live
      channel = station([ BREWERS ])
      Stations::Scheduler.extend!(channel, now: now)
      late = zone.parse("2026-10-19 21:38")

      expect(described_class.follow!(channel, now: late)).to be(true)
      expect(games_on(channel).sole.ends_at).to eq(zone.parse("2026-10-19 22:15"))
      expect(channel.airings.where("starts_at > ?", late).order(:starts_at).first.starts_at).to eq(zone.parse("2026-10-19 22:30"))
      expect(described_class.follow!(channel, now: late + 1.minute)).to be(false)
    end

    it "rebuilds what hasn't started when a game is postponed or added, at most every few minutes" do
      game(1, away: CUBS, home: BREWERS, at: "2026-10-19 18:40")
      channel = station([ BREWERS ])
      Stations::Scheduler.extend!(channel, now: now)
      games.clear
      game(2, away: CUBS, home: BREWERS, at: "2026-10-20 13:10")

      expect(described_class.follow!(channel, now: now + 1.minute)).to be(false)
      expect(described_class.follow!(channel, now: now + 15.minutes)).to be(true)
      expect(games_on(channel).map(&:mlb_game_pk)).to eq([ 2 ])
      expect(described_class.follow!(channel, now: now + 30.minutes)).to be(false)
    end

    it "changes nothing when MLB's schedule can't be read" do
      game(1, away: CUBS, home: BREWERS, at: "2026-10-19 18:40")
      channel = station([ BREWERS ])
      Stations::Scheduler.extend!(channel, now: now)
      allow(schedule).to receive(:games).and_raise(Mlb::Schedule::Error, "MLB's schedule timed out")

      expect { described_class.follow!(channel, now: now + 15.minutes) }.not_to(change { channel.airings.pluck(:id).sort })
    end
  end
end
