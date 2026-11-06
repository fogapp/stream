# typed: strict
# frozen_string_literal: true

module Nba
  # What a game from the NBA's schedule (Nba::Schedule) is doing, read from
  # the event ESPN sends.
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

    OFF = /postponed|suspended|cancel/i

    sig { params(game: T::Hash[String, T.untyped]).returns(State) }
    def self.state(game)
      type = game.dig("status", "type")
      type = {} unless type.is_a?(Hash)
      return State::Off if type["name"].to_s.match?(OFF)

      case type["state"]
      when "in" then State::Live
      when "post" then State::Final
      else State::Upcoming
      end
    end

    sig { params(game: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.live?(game) = state(game) == State::Live

    # The game's one competition, where its teams and score are.
    sig { params(game: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def self.competition(game)
      competition = Array(game["competitions"]).first
      competition.is_a?(Hash) ? competition : {}
    end

    # The home or away team's entry.
    sig { params(game: T::Hash[String, T.untyped], side: String).returns(T::Hash[String, T.untyped]) }
    def self.competitor(game, side)
      Array(competition(game)["competitors"]).grep(Hash).find { |entry| entry["homeAway"] == side } || {}
    end
  end
end
