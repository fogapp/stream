# typed: strict
# frozen_string_literal: true

module Stats
  # Tautulli in the box (PROPOSAL §7.4): who's watching what right now and
  # how, what's been watched, and the month in numbers.
  module Watching
    extend T::Sig

    LIVE = T.let(2.minutes, ActiveSupport::Duration)
    # What a session's title is read through: an episode's show, a video's
    # channel. Preloaded with the playable, for the kinds that have one.
    TITLED = T.let(%i[show channel].freeze, T::Array[Symbol])

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.now_playing
      PlaybackSession.watched.where(state: PlaybackSession::State::Active.serialize, last_seen_at: LIVE.ago..)
        .includes(:profile, media_file: %i[media_streams optimized_version], playable: TITLED).order(started_at: :desc).map { |session| session_json(session) }
    end

    sig { params(page: T.untyped).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.history(page)
      page.includes(:profile, :media_file, playable: TITLED).map { |session| session_json(session) }
    end

    sig { params(session: PlaybackSession).returns(T::Hash[Symbol, T.untyped]) }
    def self.session_json(session)
      file = session.media_file
      duration = file&.duration_seconds.to_f
      heading = PlaybackSessionSerializer.heading(session.playable)
      {
        id: session.id, title: heading[:title], subtitle: heading[:subtitle], back_path: heading[:back_path],
        profile: session.profile && { id: session.profile_id, name: session.profile&.name, color: session.profile&.color,
                                      avatar: session.profile&.avatar },
        device: session.device_name, method: session.method_enum.serialize, summary: session.stored_decision.summary,
        position_seconds: session.position_seconds.round, duration_seconds: duration.positive? ? duration.round : nil,
        progress: duration.positive? ? (session.position_seconds / duration).clamp(0, 1).round(3) : nil,
        bitrate_kbps: measured_kbps(session) || bitrate_kbps(session, duration),
        bitrate_measured: !measured_kbps(session).nil?, bytes_sent: session.bytes_sent,
        started_at: session.started_at, last_seen_at: session.last_seen_at, watched_seconds: watched_seconds(session).round
      }
    end

    # What went over the network, averaged over the session so far: the
    # bytes its media requests asked for (MediaController#count), once it
    # has run long enough that the first buffering burst has evened out.
    sig { params(session: PlaybackSession).returns(T.nilable(Integer)) }
    def self.measured_kbps(session)
      elapsed = (session.last_seen_at - session.started_at).to_f
      return nil if elapsed < 30 || session.bytes_sent.zero?

      (session.bytes_sent * 8 / elapsed / 1000).round
    end

    # An estimate before there's a measurement: the file's own rate, or the
    # optimized version's, unless it's being re-encoded.
    sig { params(session: PlaybackSession, duration: Float).returns(T.nilable(Integer)) }
    def self.bitrate_kbps(session, duration)
      case session.method_enum
      when PlaybackSession::Method::VideoTranscode then nil
      when PlaybackSession::Method::Optimized
        size = session.media_file&.optimized_version&.size
        size && duration.positive? ? (size * 8 / duration / 1000).round : nil
      else session.media_file&.bit_rate.to_i.fdiv(1000).round.nonzero?
      end
    end

    # Time actually spent, not counting a paused tab left open overnight
    # beyond the length of the thing.
    sig { params(session: PlaybackSession).returns(Float) }
    def self.watched_seconds(session)
      span = (session.last_seen_at - session.started_at).to_f
      duration = session.media_file&.duration_seconds.to_f
      duration.positive? ? span.clamp(0.0, duration) : [ span, 0.0 ].max
    end

    # The last N days: hours by profile, by library, by day, and the most
    # watched titles.
    sig { params(days: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def self.summary(days: 30)
      sessions = PlaybackSession.watched.where(started_at: days.days.ago..).includes(:profile, :media_file, playable: TITLED).to_a
      hours = ->(list) { (list.sum { |session| watched_seconds(session) } / 3600.0).round(1) }
      libraries = Library.where(id: sessions.filter_map { |session| session.media_file&.library_id }.uniq).index_by(&:id)
      {
        days: days, plays: sessions.size, hours: hours.call(sessions), bytes_sent: sessions.sum(&:bytes_sent),
        by_profile: sessions.group_by(&:profile).map do |profile, list|
          { name: profile&.name, color: profile&.color, plays: list.size, hours: hours.call(list), bytes_sent: list.sum(&:bytes_sent) }
        end
          .sort_by { |row| -row[:hours] },
        by_library: sessions.group_by { |session| session.media_file&.library_id }
          .map { |id, list| { name: (id && libraries[id]&.name) || "Unknown", plays: list.size, hours: hours.call(list) } }.sort_by { |row| -row[:hours] },
        by_day: (0...days).map do |ago|
          day = ago.days.ago.to_date
          list = sessions.select { |session| session.started_at.to_date == day }
          { date: day, plays: list.size, hours: hours.call(list) }
        end.reverse,
        most_watched: sessions.group_by { |session| title_of(session.playable) }
          .map { |title, list| { title: title, plays: list.size, hours: hours.call(list) } }.sort_by { |row| [ -row[:plays], -row[:hours] ] }.first(10)
      }
    end

    # A show's episodes count toward the show.
    sig { params(playable: T.untyped).returns(String) }
    def self.title_of(playable)
      case playable
      when Episode then playable.show&.title.to_s
      when Video then playable.channel&.title.to_s
      else playable.try(:title).to_s
      end
    end
    private_class_method :title_of
  end
end
