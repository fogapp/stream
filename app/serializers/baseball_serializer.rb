# typed: strict
# frozen_string_literal: true

# Baseball (PROPOSAL §7.8): a day's games from MLB's schedule
# (Mlb::Schedule), each as a matchup — teams, score, inning, count and
# bases, pitchers, broadcasts — and which of its teams' streams play it.
module BaseballSerializer
  extend T::Sig

  LOGO = "https://www.mlbstatic.com/team-logos"
  # The same logo drawn as a PNG, for a client that can't draw SVG (the Apple TV).
  LOGO_PNG = "https://img.mlbstatic.com/mlb-photos/image/upload/w_240,f_png,q_auto/v1/team"

  sig do
    params(date: Date, games: T::Array[T::Hash[String, T.untyped]], game_days: T::Array[Date], today: Date)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.day_json(date:, games:, game_days:, today:)
    {
      date: date.iso8601, today: today.iso8601,
      previous_date: game_days.select { |day| day < date }.max&.iso8601,
      next_date: game_days.select { |day| day > date }.min&.iso8601,
      games: games.map { |game| game_json(game) }
    }
  end

  sig { params(game: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def self.game_json(game)
    status = hash(game["status"])
    state = Mlb::Game.state(game)
    {
      id: Mlb::Game.game_pk(game), starts_at: game["gameDate"], start_time_tbd: status["startTimeTBD"] == true,
      state: state, status: [ status["detailedState"], status["reason"] ].compact.join(": "),
      watchable: Mlb::Game.watchable?(game), venue: game.dig("venue", "name"),
      series: series_json(game), double_header: game["doubleHeader"].to_s != "N" ? game["gameNumber"] : nil,
      inning: state == Mlb::Game::State::Live ? inning_json(hash(game["linescore"])) : nil,
      innings: Array(game.dig("linescore", "innings")).grep(Hash).map do |inning|
        { number: inning["num"].to_i, away: inning.dig("away", "runs"), home: inning.dig("home", "runs") }
      end,
      scheduled_innings: game.dig("linescore", "scheduledInnings") || 9,
      away: side_json(game, "away"), home: side_json(game, "home"),
      broadcasts: broadcasts_json(game),
      decisions: decisions_json(hash(game["decisions"]))
    }
  end

  sig { params(game: T::Hash[String, T.untyped], side: String).returns(T::Hash[Symbol, T.untyped]) }
  def self.side_json(game, side)
    entry = hash(game.dig("teams", side))
    team = hash(entry["team"])
    record = hash(entry["leagueRecord"])
    id = team["id"].to_i
    {
      team: {
        id: id, name: team["name"], club: team["clubName"] || team["teamName"], location: team["shortName"] || team["locationName"],
        abbreviation: team["abbreviation"], logo_url: "#{LOGO}/#{id}.svg",
        logo_png_url: "#{LOGO_PNG}/#{id}/logo/spot/current"
      },
      record: record.key?("wins") ? "#{record['wins']}-#{record['losses']}" : nil,
      score: entry["score"], hits: game.dig("linescore", "teams", side, "hits"), errors: game.dig("linescore", "teams", side, "errors"),
      winner: entry["isWinner"] == true, probable_pitcher: entry.dig("probablePitcher", "fullName")
    }
  end

  sig { params(linescore: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.inning_json(linescore)
    return nil if linescore["currentInning"].nil?

    offense = hash(linescore["offense"])
    {
      number: linescore["currentInning"].to_i, ordinal: linescore["currentInningOrdinal"].to_s,
      half: linescore["inningState"].to_s.downcase, outs: linescore["outs"].to_i, balls: linescore["balls"].to_i,
      strikes: linescore["strikes"].to_i,
      bases: { first: offense.key?("first"), second: offense.key?("second"), third: offense.key?("third") }
    }
  end

  sig { params(game: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.series_json(game)
    series = hash(game["seriesStatus"])
    return nil if series.empty? || game["gameType"] == "R"

    { name: series["shortDescription"] || series["description"], status: series["result"] }
  end

  # The TV broadcasts, once each: whose they are (home, away, or both
  # teams' — national) and their channel.
  sig { params(game: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.broadcasts_json(game)
    Array(game["broadcasts"]).grep(Hash).select { |broadcast| broadcast["type"] == "TV" && broadcast["language"].to_s.start_with?("en") }
      .group_by { |broadcast| broadcast["callSign"] || broadcast["name"] }
      .map do |name, entries|
        sides = entries.map { |broadcast| broadcast["homeAway"].to_s }.uniq
        national = entries.any? { |broadcast| broadcast["isNational"] }
        { name: name.to_s, side: national || sides.size > 1 ? "national" : sides.first.presence || "national" }
      end
  end

  sig { params(decisions: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.decisions_json(decisions)
    return nil if decisions.empty?

    { winner: decisions.dig("winner", "fullName"), loser: decisions.dig("loser", "fullName"), save: decisions.dig("save", "fullName") }
  end

  sig { params(value: T.untyped).returns(T::Hash[String, T.untyped]) }
  def self.hash(value) = value.is_a?(Hash) ? value : {}

  private_class_method :side_json, :inning_json, :series_json, :broadcasts_json, :decisions_json, :hash
end
