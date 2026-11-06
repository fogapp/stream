# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Baseball (PROPOSAL §7.8): once the household has an MLB.tv account,
    # every profile sees a day's games from MLB's schedule, and plays one
    # as the home or away team's stream (Mlb::TeamStreams).
    class BaseballController < BaseController
      before_action :require_account!, except: :show

      # Whether there's an account, so whether the sidebar shows Baseball.
      sig { void }
      def show
        render json: { available: MlbSetting.exists? }
      end

      # A day's games: the one asked for, or today's — else the next day
      # with games, else the last.
      sig { void }
      def games
        schedule = Mlb::Schedule.new
        today = Mlb::Schedule.today
        asked = parse_param_date(:date)
        game_days = schedule.game_days(asked || today)
        date = asked || (game_days.include?(today) ? today : game_days.select { |day| day > today }.min || game_days.max || today)
        render json: BaseballSerializer.day_json(date: date, games: schedule.games(date), game_days: game_days, today: today)
      rescue Mlb::Schedule::Error => e
        render_errors(e.message, status: :bad_gateway)
      end

      # The stream of the team whose broadcast to watch (side: home or
      # away), once its game is on MLB.tv.
      sig { void }
      def watch
        game = Mlb::Schedule.new.game(params[:id].to_i)
        return render_errors("That game isn't on MLB's schedule", status: :not_found) if game.nil?

        side = LiveStream::Feed.try_deserialize(params[:side].to_s) || LiveStream::Feed::Home
        team = game.dig("teams", side.serialize, "team") || {}
        unless Mlb::Game.watchable?(game)
          return render_errors(Mlb::Game.state(game) == Mlb::Game::State::Upcoming ? "MLB.tv starts this game's broadcast shortly before first pitch" :
            "This game isn't on MLB.tv now")
        end

        stream = Mlb::TeamStreams.for(current_household!.id, team["id"].to_i, team["name"].to_s)
        render json: { live_stream_id: stream.id, name: stream.name }
      rescue Mlb::Schedule::Error => e
        render_errors(e.message, status: :bad_gateway)
      end

      private

      sig { void }
      def require_account!
        render_errors("Sign in to MLB.tv in Settings › Integrations first", status: :not_found) unless MlbSetting.exists?
      end
    end
  end
end
