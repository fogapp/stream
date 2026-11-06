# typed: strict
# frozen_string_literal: true

module Mlb
  # MLB's own schedule (statsapi.mlb.com, public, no sign-in): the games of a
  # day with their teams, line score, broadcasts and pitchers, as Baseball
  # shows them and a team's stream finds its game (PROPOSAL §7.8). A day with
  # a game on is asked again every few seconds at most; any other, every few
  # minutes.
  class Schedule
    extend T::Sig
    include UpstreamHttpClient

    BASE = "https://statsapi.mlb.com/api/v1"
    HYDRATE = "team,linescore,broadcasts(all),probablePitcher,decisions,seriesStatus"
    # The major leagues.
    SPORT = 1
    LIVE_KEEP = T.let(15.seconds, ActiveSupport::Duration)
    KEEP = T.let(5.minutes, ActiveSupport::Duration)

    class Error < UpstreamHttpClient::Error; end

    sig { override.returns(String) }
    def service_name = "MLB's schedule"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # The day MLB calls today, where this server is.
    sig { returns(Date) }
    def self.today = Time.current.in_time_zone(AppSetting.cached.zone).to_date

    # Every game of the day, in MLB's order (by start).
    sig { params(date: Date).returns(T::Array[T::Hash[String, T.untyped]]) }
    def games(date)
      key = "mlb/schedule/#{date.iso8601}"
      cached = Rails.cache.read(key)
      return cached if cached.is_a?(Array)

      games = days(get("schedule", sportId: SPORT, date: date.iso8601, hydrate: HYDRATE)).flat_map { |day| Array(day["games"]) }
      Rails.cache.write(key, games, expires_in: games.any? { |game| Game.live?(game) } ? LIVE_KEEP : KEEP)
      games
    end

    # One game, asked for now.
    sig { params(game_pk: Integer).returns(T.nilable(T::Hash[String, T.untyped])) }
    def game(game_pk)
      days(get("schedule", sportId: SPORT, gamePk: game_pk, hydrate: HYDRATE)).flat_map { |day| Array(day["games"]) }.first
    end

    # The days with a game, from two months before to six after: what the
    # date strip steps through.
    sig { params(around: Date).returns(T::Array[Date]) }
    def game_days(around)
      from = around - 60
      to = around + 180
      Rails.cache.fetch("mlb/game-days/#{from.iso8601}", expires_in: 1.hour) do
        days(get("schedule", sportId: SPORT, startDate: from.iso8601, endDate: to.iso8601, fields: "dates,date")).map { |day| day["date"].to_s }
      end.filter_map { |text| date_of(text) }
    end

    # The game the team is on MLB.tv in now: today's, or last night's still
    # going past midnight; the one playing over one about to.
    sig { params(team_id: Integer).returns(T.nilable(T::Hash[String, T.untyped])) }
    def watchable_game(team_id)
      today = self.class.today
      [ today - 1, today ].flat_map { |date| games(date) }
        .select { |game| Game.watchable?(game) && Game.team_ids(game).include?(team_id) }
        .max_by { |game| [ Game.live?(game) ? 1 : 0, game["gameDate"].to_s ] }
    end

    # The major league clubs, [{ "id", "name", "abbreviation" }] by name.
    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def teams
      Rails.cache.fetch("mlb/teams/#{self.class.today.year}", expires_in: 1.day) do
        Array(parse_object(http_get(url("teams", sportId: SPORT)))["teams"]).select { |team| team.is_a?(Hash) && team["active"] }
          .map { |team| { "id" => team["id"].to_i, "name" => team["name"].to_s, "abbreviation" => team["abbreviation"].to_s } }
          .sort_by { |team| team["name"] }
      end
    end

    private

    sig { params(path: String, query: T.untyped).returns(T::Hash[String, T.untyped]) }
    def get(path, **query) = parse_object(http_get(url(path, **query)))

    sig { params(path: String, query: T.untyped).returns(String) }
    def url(path, **query) = "#{BASE}/#{path}?#{URI.encode_www_form(query)}"

    sig { params(text: String).returns(T.nilable(Date)) }
    def date_of(text)
      Date.iso8601(text)
    rescue Date::Error
      nil
    end

    sig { params(data: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[String, T.untyped]]) }
    def days(data) = Array(data["dates"]).grep(Hash)
  end
end
