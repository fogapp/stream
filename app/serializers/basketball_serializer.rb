# typed: strict
# frozen_string_literal: true

# Basketball (PROPOSAL §7.8): a day's games from the NBA's schedule
# (Nba::Schedule), each as a matchup — teams, records, score, quarter and
# clock, line score, broadcasts — and where to watch it on NBA.com.
module BasketballSerializer
  extend T::Sig

  # League Pass's games of a day; a game's own page needs NBA.com's id,
  # which ESPN doesn't have.
  WATCH = "https://www.nba.com/games"
  QUARTERS = 4

  sig do
    params(date: Date, games: T::Array[T::Hash[String, T.untyped]], game_days: T::Array[Date], today: Date)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.day_json(date:, games:, game_days:, today:)
    {
      date: date.iso8601, today: today.iso8601,
      previous_date: game_days.select { |day| day < date }.max&.iso8601,
      next_date: game_days.select { |day| day > date }.min&.iso8601,
      watch_url: "#{WATCH}?#{URI.encode_www_form(date: date.iso8601)}",
      games: games.map { |game| game_json(game) }
    }
  end

  sig { params(game: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def self.game_json(game)
    competition = Nba::Game.competition(game)
    status = hash(game["status"])
    away = Nba::Game.competitor(game, "away")
    home = Nba::Game.competitor(game, "home")
    {
      id: game["id"].to_s, starts_at: game["date"], start_time_tbd: competition["timeValid"] == false,
      state: Nba::Game.state(game), status: hash(status["type"])["shortDetail"].to_s,
      period: status["period"].to_i, venue: competition.dig("venue", "fullName"),
      preseason: game.dig("season", "type") == 1, series: series_json(competition),
      periods: periods_json(away, home), scheduled_periods: QUARTERS,
      away: side_json(game, away), home: side_json(game, home),
      broadcasts: broadcasts_json(competition)
    }
  end

  sig { params(game: T::Hash[String, T.untyped], entry: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def self.side_json(game, entry)
    team = hash(entry["team"])
    record = Array(entry["records"]).grep(Hash).find { |candidate| candidate["type"] == "total" }
    played = [ Nba::Game::State::Live, Nba::Game::State::Final ].include?(Nba::Game.state(game))
    {
      team: {
        id: team["id"].to_s, name: team["displayName"], club: team["shortDisplayName"] || team["name"], location: team["location"],
        abbreviation: team["abbreviation"], logo_url: team["logo"], logo_dark_url: team["logoDark"] || team["logo"]
      },
      record: record&.dig("summary"),
      score: played && entry["score"].present? ? entry["score"].to_i : nil,
      winner: entry["winner"] == true,
      leader: leader_json(entry)
    }
  end

  # The team's top scorer of the game so far.
  sig { params(entry: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.leader_json(entry)
    points = Array(entry["leaders"]).grep(Hash).find { |category| category["name"] == "points" }
    leader = Array(points&.dig("leaders")).grep(Hash).first
    return nil if leader.nil?

    { name: leader.dig("athlete", "shortName") || leader.dig("athlete", "displayName"), points: leader["value"].to_i }
  end

  # Points by quarter, overtimes after.
  sig { params(away: T::Hash[String, T.untyped], home: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.periods_json(away, home)
    by_period = ->(entry) { Array(entry["linescores"]).grep(Hash).to_h { |line| [ line["period"].to_i, line["value"]&.to_i ] } }
    away_points = by_period.call(away)
    home_points = by_period.call(home)
    (away_points.keys | home_points.keys).sort.map { |number| { number: number, away: away_points[number], home: home_points[number] } }
  end

  # In the playoffs: the round and game, and the series so far.
  sig { params(competition: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.series_json(competition)
    series = hash(competition["series"])
    name = Array(competition["notes"]).grep(Hash).filter_map { |note| note["headline"].presence }.first
    return nil if name.nil? && series.empty?

    { name: name, status: series["summary"] }
  end

  # The TV broadcasts, once each: whose they are (home, away, or
  # national) and their channel.
  sig { params(competition: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.broadcasts_json(competition)
    Array(competition["broadcasts"]).grep(Hash).flat_map do |broadcast|
      side = %w[home away].include?(broadcast["market"]) ? broadcast["market"] : "national"
      Array(broadcast["names"]).map { |name| { name: name.to_s, side: side } }
    end.uniq { |broadcast| broadcast[:name] }
  end

  sig { params(value: T.untyped).returns(T::Hash[String, T.untyped]) }
  def self.hash(value) = value.is_a?(Hash) ? value : {}

  private_class_method :side_json, :leader_json, :periods_json, :series_json, :broadcasts_json, :hash
end
