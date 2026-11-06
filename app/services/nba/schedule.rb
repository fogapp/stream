# typed: strict
# frozen_string_literal: true

module Nba
  # The NBA's schedule as ESPN's scoreboard has it (site.api.espn.com,
  # public, no sign-in): a day's games with their teams, records, quarter
  # and clock, line score and broadcasts, and the season's game days, as
  # Basketball shows them (PROPOSAL §7.8). NBA.com's own feed turns away
  # anything that isn't a browser. A day with a game on is asked again
  # every few seconds at most; any other, every few minutes.
  class Schedule
    extend T::Sig
    include UpstreamHttpClient

    SCOREBOARD = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard"
    LIVE_KEEP = T.let(15.seconds, ActiveSupport::Duration)
    KEEP = T.let(5.minutes, ActiveSupport::Duration)

    class Error < UpstreamHttpClient::Error; end

    sig { override.returns(String) }
    def service_name = "NBA's schedule"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # The day the NBA calls today, where this server is.
    sig { returns(Date) }
    def self.today = Time.current.in_time_zone(AppSetting.cached.zone).to_date

    # Every game of the day (an Eastern day, as the NBA's are), by start.
    sig { params(date: Date).returns(T::Array[T::Hash[String, T.untyped]]) }
    def games(date) = Array(scoreboard(date)["events"]).grep(Hash)

    # The days of the season around `date` that have a game: what the date
    # strip steps through.
    sig { params(date: Date).returns(T::Array[Date]) }
    def game_days(date)
      calendar = Array(scoreboard(date).dig("leagues", 0, "calendar"))
      calendar.filter_map { |day| date_of(day.is_a?(Hash) ? day["startDate"].to_s : day.to_s) }.uniq.sort
    end

    # Settings' Test button: NBA's schedule can be read from here.
    sig { returns([ T::Boolean, String ]) }
    def test_connection
      answer_test do
        count = games(self.class.today).size
        "Read NBA's schedule: #{count.zero? ? 'no games' : "#{count} #{count == 1 ? 'game' : 'games'}"} today"
      end
    end

    private

    sig { params(date: Date).returns(T::Hash[String, T.untyped]) }
    def scoreboard(date)
      key = "nba/scoreboard/#{date.iso8601}"
      cached = Rails.cache.read(key)
      return cached if cached.is_a?(Hash)

      data = parse_object(http_get("#{SCOREBOARD}?#{URI.encode_www_form(dates: date.strftime('%Y%m%d'))}"), strict: true)
      live = Array(data["events"]).grep(Hash).any? { |game| Game.live?(game) }
      Rails.cache.write(key, data, expires_in: live ? LIVE_KEEP : KEEP)
      data
    end

    # "2026-10-21T07:00Z" is the 21st: ESPN's days start at Pacific midnight.
    sig { params(text: String).returns(T.nilable(Date)) }
    def date_of(text)
      Date.iso8601(text[0, 10].to_s)
    rescue Date::Error
      nil
    end
  end
end
