# typed: strict
# frozen_string_literal: true

module Stations
  # A channel's teams' games (PROPOSAL §7.7, §7.8): whenever one of its clubs
  # plays, the game is on, over whatever the blocks would have aired. A game
  # is given its slot from first pitch (back to the quarter hour) for three
  # hours, and plays the team's MLB.tv stream (Mlb::TeamStreams) — the
  # broadcast of whichever of the channel's teams is listed first. Two of its
  # teams playing at once: the game of the one listed first.
  #
  # The slot is a guess; `follow!`, every minute, keeps it true: a game
  # that's over ends its slot there, one still going is given more time, and
  # a schedule that changed (a postponement, a playoff game added) rebuilds
  # what hasn't started.
  module Games
    extend T::Sig

    class Slot < T::Struct
      const :game_pk, Integer
      # Whose broadcast plays.
      const :team_id, Integer
      const :team_name, String
      const :starts_at, ActiveSupport::TimeWithZone
      const :ends_at, ActiveSupport::TimeWithZone
      const :title, String
      const :subtitle, T.nilable(String)
      # The ballpark's date, MLB's own.
      const :official_date, String
    end

    # Why there are no games to schedule, said on the channel's settings.
    class Unavailable < StandardError; end

    LENGTH = T.let(3.hours, ActiveSupport::Duration)
    # A game still going this near its slot's end is given this much more.
    MORE = T.let(30.minutes, ActiveSupport::Duration)
    NEAR_END = T.let(10.minutes, ActiveSupport::Duration)
    # However long a game goes, its slot ends by then (a suspended game that
    # MLB never marks so).
    LONGEST = T.let(8.hours, ActiveSupport::Duration)
    # A schedule that changed rebuilds the channel at most this often: what
    # one rebuild can't place, the next won't either.
    REBUILD_EVERY = T.let(10.minutes, ActiveSupport::Duration)
    QUARTER = 15

    # The games to air between two moments, in order, none overlapping.
    # Raises Unavailable when they can't be known.
    sig do
      params(station: Station, from: ActiveSupport::TimeWithZone, to: ActiveSupport::TimeWithZone, now: ActiveSupport::TimeWithZone,
        zone: ActiveSupport::TimeZone).returns(T::Array[Slot])
    end
    def self.slots(station, from:, to:, now:, zone:)
      teams = station.mlb_team_ids
      return [] if teams.empty?

      games = games_for(station, from, to, zone).reject { |game| ended?(game) }
      made = T.let({}, T::Hash[Integer, Slot])
      # A doubleheader's second game has no time of its own: it follows the first.
      games.sort_by { |game| [ tbd?(game) ? 1 : 0, game["gameNumber"].to_i ] }.each do |game|
        starts = start_of(game, made, zone)
        next if starts.nil?

        # Three hours from first pitch; a second game's, from the first's end.
        ends = ceil((tbd?(game) ? starts : pitch(game, zone) || starts) + LENGTH, zone)
        ends = ceil(now + MORE, zone) if Mlb::Game.live?(game) && ends < now + NEAR_END
        team_id = T.must((Mlb::Game.team_ids(game) & teams).min_by { |id| teams.index(id).to_i })
        made[Mlb::Game.game_pk(game)] = Slot.new(game_pk: Mlb::Game.game_pk(game), team_id: team_id, team_name: team_name(game, team_id),
          starts_at: starts, ends_at: ends, title: title(game), subtitle: subtitle(game), official_date: game["officialDate"].to_s)
      end
      # The channel's first team's games first; a game that would overlap one
      # already kept isn't.
      kept = T.let([], T::Array[Slot])
      made.values.sort_by { |slot| [ teams.index(slot.team_id).to_i, slot.starts_at ] }.each do |slot|
        next if slot.ends_at <= from || slot.starts_at >= to
        next if kept.any? { |other| other.starts_at < slot.ends_at && slot.starts_at < other.ends_at }

        kept << slot
      end
      kept.sort_by(&:starts_at)
    end

    # The game on now, kept true to the game; and what hasn't started,
    # rebuilt when MLB's schedule no longer matches it. Whether anything
    # changed.
    sig { params(station: Station, now: ActiveSupport::TimeWithZone).returns(T::Boolean) }
    def self.follow!(station, now: Time.current)
      return false if station.mlb_team_ids.empty? || station.streams?

      zone = AppSetting.cached.zone
      through = station.scheduled_through || now
      on = station.airing_at(now)
      on = nil if on&.mlb_game_pk.nil?
      games = games_for(station, now - LONGEST, through, zone).index_by { |game| Mlb::Game.game_pk(game) }
      if on && (ends = new_end(on, games[on.mlb_game_pk.to_i], now, zone))
        on.update!(ends_at: ends)
        Scheduler.rebuild!(station, now: now)
        return true
      end
      return false if station.last_scheduled_at && T.must(station.last_scheduled_at) > now - REBUILD_EVERY
      return false if matches?(station, slots(station, from: now, to: through, now: now, zone: zone), on, now)

      Scheduler.rebuild!(station, now: now)
      true
    rescue Unavailable, Mlb::Schedule::Error => e
      Rails.logger.info("[grid] channel #{station.number} couldn't follow its games: #{e.message}")
      false
    end

    # When the game on now should end instead, if it should: now, once it's
    # over; later, while it's still going and its slot nearly isn't.
    sig do
      params(airing: Airing, game: T.nilable(T::Hash[String, T.untyped]), now: ActiveSupport::TimeWithZone, zone: ActiveSupport::TimeZone)
        .returns(T.nilable(ActiveSupport::TimeWithZone))
    end
    def self.new_end(airing, game, now, zone)
      # Not in MLB's answer at all: nothing to go on, so nothing changes.
      return nil if game.nil?

      over = ended?(game)
      return now if over && airing.ends_at > now + 1.minute
      return nil if over || airing.ends_at > now + NEAR_END

      longest = airing.starts_at + LONGEST
      ends = [ ceil(now + MORE, zone), longest ].min
      ends > airing.ends_at ? ends : nil
    end

    # Whether what's scheduled after now has the games it should: each game
    # to come on, where its slot is (joined late, when the game before ran
    # long), and no game that shouldn't be.
    sig { params(station: Station, slots: T::Array[Slot], on: T.nilable(Airing), now: ActiveSupport::TimeWithZone).returns(T::Boolean) }
    def self.matches?(station, slots, on, now)
      aired = Airing.unscoped.where(station_id: station.id).where("starts_at > ?", now).where.not(mlb_game_pk: nil).to_a
      wanted = slots.select { |slot| slot.starts_at > now && (on.nil? || slot.ends_at > on.ends_at) && slot.game_pk != on&.mlb_game_pk }
      wanted.all? do |slot|
        aired.any? { |airing| airing.mlb_game_pk == slot.game_pk && airing.starts_at >= slot.starts_at && airing.starts_at < slot.ends_at }
      end && aired.all? { |airing| wanted.any? { |slot| slot.game_pk == airing.mlb_game_pk } }
    end

    # The channel's teams' games around two moments, each once — those off
    # too, so a game suspended while it's on ends its slot.
    sig do
      params(station: Station, from: ActiveSupport::TimeWithZone, to: ActiveSupport::TimeWithZone, zone: ActiveSupport::TimeZone)
        .returns(T::Array[T::Hash[String, T.untyped]])
    end
    def self.games_for(station, from, to, zone)
      unless MlbSetting.unscoped.exists?(household_id: station.household_id)
        raise Unavailable, "Sign in to MLB.tv in Settings › Integrations for its teams' games"
      end

      schedule = Mlb::Schedule.new
      # MLB's dates are the ballpark's: a day either side covers every zone.
      dates = ((from.in_time_zone(zone).to_date - 1)..(to.in_time_zone(zone).to_date + 1)).first(10)
      teams = station.mlb_team_ids
      dates.flat_map { |date| schedule.games(date) }
        .select { |game| Mlb::Game.team_ids(game).intersect?(teams) }
        # A game suspended and resumed is on both days: the later is the one that's on.
        .group_by { |game| Mlb::Game.game_pk(game) }.map { |_, same| T.must(same.max_by { |game| game["gameDate"].to_s }) }
    end

    sig { params(game: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.ended?(game)
      state = Mlb::Game.state(game)
      state == Mlb::Game::State::Final || state == Mlb::Game::State::Off
    end

    sig { params(game: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.tbd?(game) = game.dig("status", "startTimeTBD") == true

    # First pitch, back to the quarter hour; a second game of a
    # doubleheader with no time of its own, as the first one's slot ends.
    sig do
      params(game: T::Hash[String, T.untyped], made: T::Hash[Integer, Slot], zone: ActiveSupport::TimeZone)
        .returns(T.nilable(ActiveSupport::TimeWithZone))
    end
    def self.start_of(game, made, zone)
      if tbd?(game)
        first = made.values.find { |slot| slot.official_date == game["officialDate"].to_s && slot.title == title(game) }
        return first&.ends_at
      end

      at = pitch(game, zone)
      at && floor(at, zone)
    end

    sig { params(game: T::Hash[String, T.untyped], zone: ActiveSupport::TimeZone).returns(T.nilable(ActiveSupport::TimeWithZone)) }
    def self.pitch(game, zone)
      Time.iso8601(game["gameDate"].to_s).in_time_zone(zone)
    rescue ArgumentError
      nil
    end

    sig { params(time: ActiveSupport::TimeWithZone, zone: ActiveSupport::TimeZone).returns(ActiveSupport::TimeWithZone) }
    def self.floor(time, zone)
      local = time.in_time_zone(zone).change(sec: 0)
      local - (local.min % QUARTER).minutes
    end

    sig { params(time: ActiveSupport::TimeWithZone, zone: ActiveSupport::TimeZone).returns(ActiveSupport::TimeWithZone) }
    def self.ceil(time, zone)
      floored = floor(time, zone)
      floored == time ? floored : floored + QUARTER.minutes
    end

    # "Cubs at Brewers".
    sig { params(game: T::Hash[String, T.untyped]).returns(String) }
    def self.title(game)
      away, home = %w[away home].map do |side|
        team = game.dig("teams", side, "team") || {}
        (team["teamName"] || team["clubName"] || team["name"]).to_s
      end
      "#{away} at #{home}"
    end

    # A playoff game's series and number; a doubleheader's game; else nothing.
    sig { params(game: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def self.subtitle(game)
      if game["gameType"].present? && game["gameType"] != "R" && game["seriesDescription"].present?
        number = game["seriesGameNumber"]
        return [ game["seriesDescription"], number && "Game #{number}" ].compact.join(" · ")
      end
      game["doubleHeader"].to_s.in?(%w[Y S]) ? "Game #{game['gameNumber']} of 2" : nil
    end

    sig { params(game: T::Hash[String, T.untyped], team_id: Integer).returns(String) }
    def self.team_name(game, team_id)
      side = Mlb::Game.side(game, team_id) == LiveStream::Feed::Away ? "away" : "home"
      game.dig("teams", side, "team", "name").to_s
    end

    private_class_method :new_end, :matches?, :games_for, :ended?, :tbd?, :start_of, :pitch, :floor, :ceil, :title, :subtitle, :team_name
  end
end
