# typed: strict
# frozen_string_literal: true

module Playback
  # The Playback page's Sessions table: every press of Play, with what its
  # player reported counted in SQL so the table can filter and sort on it —
  # stalls, errors, the time to the first frame and the outcome — across
  # however many sessions there are, a page at a time.
  class SessionQuery
    extend T::Sig

    Outcome = PlaybackSession::Outcome

    TITLE = TitleSql::TITLE
    JOINS = T.let([
      *TitleSql.joins("playback_sessions.playable_type", "playback_sessions.playable_id"),
      "LEFT JOIN media_files ON media_files.id = playback_sessions.media_file_id",
      "LEFT JOIN profiles ON profiles.id = playback_sessions.profile_id",
      "LEFT JOIN devices ON devices.id = playback_sessions.device_id"
    ].freeze, T::Array[String])

    # Each kind of event, counted per session.
    COUNT = T.let(lambda { |kind|
      "(SELECT count(*) FROM playback_events e WHERE e.playback_session_id = playback_sessions.id AND e.kind = '#{kind}')"
    }, T.proc.params(kind: String).returns(String))

    # The first startup the player timed; a value that isn't a number is no time at all.
    STARTUP = T.let(<<~SQL.squish, String)
      (SELECT CASE WHEN e.detail->>'ms' ~ '^[0-9]+(\\.[0-9]+)?$' THEN (e.detail->>'ms')::float END
       FROM playback_events e WHERE e.playback_session_id = playback_sessions.id AND e.kind = 'startup'
       ORDER BY e.created_at LIMIT 1)
    SQL

    OUTCOME = T.let(<<~SQL.squish, String)
      CASE WHEN playback_sessions.transcode_error IS NOT NULL THEN 'failed'
           WHEN #{COUNT.call('error')} > 0 THEN 'errored'
           WHEN #{COUNT.call('stall')} > 0 THEN 'stalled'
           ELSE 'clean' END
    SQL

    # What each sortable column sorts by, on the inner query's names.
    SORTS = T.let({
      "started_at" => "started_at", "title" => "lower(title)", "method" => "method", "profile" => "lower(profile_name)",
      "device" => "lower(device_label)", "startup_ms" => "startup_ms", "stalls" => "stalls_count", "errors" => "errors_count",
      "outcome" => "CASE outcome WHEN 'failed' THEN 0 WHEN 'errored' THEN 1 WHEN 'stalled' THEN 2 ELSE 3 END"
    }.freeze, T::Hash[String, String])

    # Each column either way, as a whole ORDER BY: ties broken newest first,
    # so a page boundary never shuffles.
    ORDERS = T.let(SORTS.flat_map do |key, column|
      %w[asc desc].map { |direction| [ "#{key} #{direction}", "#{column} #{direction.upcase} NULLS LAST, started_at DESC, id" ] }
    end.to_h.freeze, T::Hash[String, String])

    COLUMNS = T.let([
      "playback_sessions.*", "#{TITLE} AS title", "profiles.name AS profile_name",
      "COALESCE(devices.name, playback_sessions.device_name) AS device_label",
      "#{COUNT.call('stall')} AS stalls_count", "#{COUNT.call('error')} AS errors_count",
      "#{COUNT.call('recovery')} AS recoveries_count", "#{STARTUP} AS startup_ms", "#{OUTCOME} AS outcome"
    ].freeze, T::Array[String])

    class Filters < T::Struct
      const :query, T.nilable(String), default: nil
      const :play_methods, T::Array[PlaybackSession::Method], default: []
      const :outcomes, T::Array[PlaybackSession::Outcome], default: []
      const :profile_id, T.nilable(String), default: nil
      const :device_id, T.nilable(String), default: nil
      const :from, T.nilable(T.any(Time, ActiveSupport::TimeWithZone)), default: nil
      const :to, T.nilable(T.any(Time, ActiveSupport::TimeWithZone)), default: nil
      const :sort, String, default: "started_at"
      const :direction, String, default: "desc"
    end

    sig { params(filters: Filters).void }
    def initialize(filters)
      @filters = filters
    end

    # Sessions with their counts as attributes (stalls_count, errors_count,
    # recoveries_count, startup_ms, outcome, title), filtered and in order.
    sig { returns(T.untyped) }
    def scope
      # Everything inner made: left to itself, a model with ignored_columns
      # lists its own columns, and the counts would be lost. The id as well,
      # for paging's count to take as its one column.
      outer = PlaybackSession.from(inner, :playback_sessions).select("playback_sessions.*", "playback_sessions.id")
      outer = outer.where(outcome: @filters.outcomes.map(&:serialize)) if @filters.outcomes.any?
      direction = @filters.direction == "asc" ? "asc" : "desc"
      outer.order(Arel.sql(ORDERS.fetch("#{@filters.sort} #{direction}", ORDERS.fetch("started_at desc"))))
    end

    private

    sig { returns(T.untyped) }
    def inner
      scope = PlaybackSession.watched.joins(JOINS).select(COLUMNS)
      scope = scope.where(method: @filters.play_methods.map(&:serialize)) if @filters.play_methods.any?
      scope = scope.where(profile_id: @filters.profile_id) if @filters.profile_id
      scope = scope.where(device_id: @filters.device_id) if @filters.device_id
      scope = scope.where(started_at: @filters.from..) if @filters.from
      scope = scope.where(started_at: ..@filters.to) if @filters.to
      if (query = @filters.query.presence)
        scope = scope.where("#{TITLE} ILIKE :q OR media_files.path ILIKE :q", q: "%#{PlaybackSession.sanitize_sql_like(query)}%")
      end
      scope
    end
  end
end
