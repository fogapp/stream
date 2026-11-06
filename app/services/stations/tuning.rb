# typed: strict
# frozen_string_literal: true

module Stations
  # Pressing Play on Grid (PROPOSAL §7.7): station_id tunes to what's on now;
  # airing_id plays one airing — restarting it, or a part of it;
  # after_airing_id plays whatever follows one, as the schedule now has it —
  # the next program, as the one on screen ends. A channel that shows a
  # camera or web stream (§7.8) tunes to the stream.
  class Tuning
    extend T::Sig

    # How far back an airing can be played, behind live (Restart, and the
    # parts that follow it).
    DVR_WINDOW = T.let(4.hours, ActiveSupport::Duration)

    # How early the next program on a channel can be played: a file that
    # ran out a few seconds before its slot goes straight on to the next,
    # rather than a slate for a moment. Tuned ahead, it can be readied
    # earlier than that (READY_EARLY).
    FOLLOWING_EARLY = T.let(5.seconds, ActiveSupport::Duration)
    READY_EARLY = T.let(2.minutes, ActiveSupport::Duration)

    # Tuning in this near an airing's end joins what follows it instead:
    # less than a GOP of it left is a seek and a prewarm for nothing.
    TAIL = T.let(10.seconds, ActiveSupport::Duration)

    # Nothing to play yet: a 409 the players show as the slate, with when to
    # ask again — the next program's start — when that's known.
    class Refused < StandardError
      extend T::Sig

      sig { returns(T.nilable(Integer)) }
      attr_reader :retry_after

      sig { params(message: String, retry_after: T.nilable(Integer)).void }
      def initialize(message, retry_after: nil)
        super(message)
        @retry_after = retry_after
      end
    end

    sig do
      params(station_id: T.nilable(String), airing_id: T.nilable(String), after_airing_id: T.nilable(String), standby: T::Boolean,
        now: ActiveSupport::TimeWithZone).void
    end
    def initialize(station_id:, airing_id:, after_airing_id:, standby:, now: Time.current)
      @station_id = station_id
      @airing_id = airing_id
      @after_airing_id = after_airing_id
      @standby = standby
      @now = now
      @station = T.let(nil, T.nilable(Station))
    end

    # The stream of a channel that shows one.
    sig { returns(T.nilable(LiveStream)) }
    def stream
      return nil if @station_id.nil?

      channel = allowed_station
      channel.streams? ? channel.live_stream : nil
    end

    # The airing asked for, if one was. Raises Refused when there's nothing
    # to play yet.
    sig { returns(T.nilable(Airing)) }
    def airing
      if @station_id then on_now(allowed_station)
      elsif @after_airing_id then after(Airing.find(@after_airing_id))
      elsif @airing_id then replay(Airing.find(@airing_id))
      end
    end

    # Where live is in this airing, or earlier when asked (Restart, or
    # rewinding), never later: live TV can't be ahead of itself. `behind`
    # keeps a viewer as far behind live as they were, from one program to
    # the next.
    sig { params(airing: Airing, start: T.nilable(Float), behind: T.nilable(Float)).returns(Float) }
    def self.start_of(airing, start:, behind:)
      now = Time.current
      live = airing.position_at(now)
      return start.clamp(airing.media_start, live) if start

      kept = behind.to_f.clamp(0.0, DVR_WINDOW.to_f)
      kept.positive? ? airing.position_at(now - kept.seconds) : live
    end

    private

    # A channel this profile may see airs only what it may see
    # (Viewing::Access.stations): checked once, when tuning to it.
    sig { returns(Station) }
    def allowed_station
      @station ||= allowed(Station.find(T.must(@station_id)))
    end

    sig { params(station: T.nilable(Station)).returns(Station) }
    def allowed(station)
      raise ActiveRecord::RecordNotFound unless station && Viewing::Access.allows?(station)

      station
    end

    sig { params(station: Station).returns(Airing) }
    def on_now(station)
      airing = station.airing_at(@now)
      raise gap(station, "Nothing's on this channel right now") if airing.nil?

      # Its last seconds: what follows instead, when it follows straight on.
      following = airing.ends_at - @now < TAIL ? airing.following : nil
      following && following.starts_at <= airing.ends_at + FOLLOWING_EARLY ? following : airing
    end

    # A moment early is the next program being readied; any earlier isn't
    # live TV. Behind live like a DVR: back as far as the program it's part of.
    sig { params(airing: Airing).returns(Airing) }
    def replay(airing)
      allowed(airing.station)
      raise Refused, "That hasn't started yet" if airing.starts_at > @now + READY_EARLY
      raise Refused, "That was too long ago" if airing.ends_at <= @now - DVR_WINDOW

      airing
    end

    # The program after one that just finished: played a few seconds early
    # rather than a slate (or readied earlier, on standby); after a longer
    # gap, a slate until it starts — Retry-After says when.
    sig { params(previous: Airing).returns(Airing) }
    def after(previous)
      station = allowed(T.must(previous.station))
      airing = previous.following
      outcome = if airing.nil? then "nothing"
      elsif airing.starts_at > @now + (@standby ? READY_EARLY : FOLLOWING_EARLY) then "gap"
      elsif airing.ends_at <= @now - DVR_WINDOW then "too_late"
      else "tuned"
      end
      # How the moves from one program to the next go (Lucid): a gap is a
      # slate on purpose, "nothing" a schedule that ran out.
      Lucid.increment("live.program_changes", tags: { outcome: outcome, standby: @standby.to_s })
      return T.must(airing) if outcome == "tuned"
      raise gap(station, "That hasn't started yet", until_time: airing&.starts_at) if outcome == "gap"
      raise gap(station, "Nothing's on this channel right now") if outcome == "nothing"

      raise Refused, "That was too long ago"
    end

    sig { params(station: Station, message: String, until_time: T.nilable(ActiveSupport::TimeWithZone)).returns(Refused) }
    def gap(station, message, until_time: nil)
      upcoming = until_time || station.airings.where("starts_at > ?", @now).minimum(:starts_at)
      Refused.new(message, retry_after: upcoming && [ (upcoming - @now).ceil, 1 ].max)
    end
  end
end
