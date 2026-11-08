# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Basketball (PROPOSAL §7.8): once the household turns on NBA League
    # Pass, every profile sees a day's games from the NBA's schedule, and
    # watches one on NBA.com.
    class BasketballController < BaseController
      before_action :require_league_pass!, except: :show
      answers_upstream_errors Nba::Schedule::Error

      # Whether League Pass is on, so whether the sidebar shows Basketball.
      sig { void }
      def show
        render json: { available: NbaSetting.exists? }
      end

      # A day's games: the one asked for, or today's — else the next day
      # with games, else the last.
      sig { void }
      def games
        schedule = Nba::Schedule.new
        today = Nba::Schedule.today
        asked = parse_param_date(:date)
        game_days = schedule.game_days(asked || today)
        date = asked || (game_days.include?(today) ? today : game_days.select { |day| day > today }.min || game_days.max || today)
        render json: BasketballSerializer.day_json(date: date, games: schedule.games(date), game_days: game_days, today: today)
      end

      private

      sig { void }
      def require_league_pass!
        render_errors("Turn on NBA League Pass in Settings › Integrations first", status: :not_found) unless NbaSetting.exists?
      end
    end
  end
end
