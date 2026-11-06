# typed: strict
# frozen_string_literal: true

module Mlb
  # What a game from MLB's schedule (Mlb::Schedule) is doing, read from the
  # hash MLB sends: Baseball's cards and a team's stream ask the same way.
  module Game
    extend T::Sig

    class State < T::Enum
      include ApplicationEnum
      enums do
        Upcoming = new("upcoming")
        Live = new("live")
        Final = new("final")
        # Postponed, suspended or cancelled.
        Off = new("off")
      end
    end

    # MLB.tv starts a game's broadcast in the warm-up, before first pitch.
    BEFORE_FIRST_PITCH = T.let(%w[Pre-Game Warmup].freeze, T::Array[String])
    OFF = /postponed|suspended|cancel/i

    sig { params(game: T::Hash[String, T.untyped]).returns(State) }
    def self.state(game)
      status = game["status"].is_a?(Hash) ? game["status"] : {}
      return State::Off if status["detailedState"].to_s.match?(OFF)

      case status["abstractGameState"]
      when "Live" then State::Live
      when "Final" then State::Final
      else State::Upcoming
      end
    end

    sig { params(game: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.live?(game) = state(game) == State::Live

    # On MLB.tv now, or about to be.
    sig { params(game: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.watchable?(game)
      live?(game) || (state(game) == State::Upcoming && BEFORE_FIRST_PITCH.include?(game.dig("status", "detailedState")))
    end

    sig { params(game: T::Hash[String, T.untyped]).returns(T::Array[Integer]) }
    def self.team_ids(game) = %w[away home].filter_map { |side| game.dig("teams", side, "team", "id")&.to_i }

    # Which side the team is on, home or away.
    sig { params(game: T::Hash[String, T.untyped], team_id: Integer).returns(LiveStream::Feed) }
    def self.side(game, team_id)
      game.dig("teams", "away", "team", "id").to_i == team_id ? LiveStream::Feed::Away : LiveStream::Feed::Home
    end

    sig { params(game: T::Hash[String, T.untyped]).returns(Integer) }
    def self.game_pk(game) = game["gamePk"].to_i
  end
end
