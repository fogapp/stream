# typed: strict
# frozen_string_literal: true

module Playback
  # The Playback page's Queue and Optimized tables: optimized versions with
  # what they're versions of, where each queued one stands in line (the
  # transcoder's own order), how long each took to encode, when its file
  # was last played and how often the version has played since it was
  # made — all in SQL, so the tables filter and sort across every version.
  class OptimizedQuery
    extend T::Sig

    JOINS = T.let([
      "LEFT JOIN media_files ON media_files.id = optimized_versions.media_file_id",
      "LEFT JOIN LATERAL (SELECT e.playable_type, e.playable_id FROM editions e " \
      "WHERE e.media_file_id = optimized_versions.media_file_id ORDER BY e.created_at LIMIT 1) edition ON true",
      *TitleSql.joins("edition.playable_type", "edition.playable_id")
    ].freeze, T::Array[String])

    COLUMNS = T.let([
      "optimized_versions.*", "#{TitleSql::TITLE} AS title", "media_files.path AS file_path",
      "CASE WHEN optimized_versions.state = 'queued' THEN " \
      "row_number() OVER (PARTITION BY optimized_versions.state ORDER BY #{OptimizedVersion::QUEUE_ORDER_SQL}) END AS queue_position",
      "EXTRACT(EPOCH FROM (optimized_versions.finished_at - optimized_versions.started_at)) AS encode_seconds",
      "(SELECT max(ps.started_at) FROM playback_sessions ps WHERE ps.media_file_id = optimized_versions.media_file_id " \
      "AND ps.standby = false) AS last_played_at",
      "(SELECT count(*) FROM playback_sessions ps WHERE ps.media_file_id = optimized_versions.media_file_id " \
      "AND ps.standby = false AND ps.method = 'optimized' AND ps.started_at >= optimized_versions.finished_at) AS plays_since"
    ].freeze, T::Array[String])

    # Encoding, then the queue in line, then the rest: what "queue order"
    # means across states.
    STATE_ORDER = "CASE state WHEN 'encoding' THEN 0 WHEN 'queued' THEN 1 WHEN 'failed' THEN 2 WHEN 'ready' THEN 3 ELSE 4 END"

    SORTS = T.let({
      "queue" => "#{STATE_ORDER}, queue_position", "title" => "lower(title)", "created_at" => "created_at",
      "finished_at" => "finished_at", "size" => "size", "encode_seconds" => "encode_seconds", "plays" => "plays_since",
      "last_played_at" => "last_played_at", "attempts" => "attempts", "needed_at" => "needed_at",
      "interruptions" => "interruptions", "progress" => "progress"
    }.freeze, T::Hash[String, String])

    ORDERS = T.let(SORTS.flat_map do |key, column|
      %w[asc desc].map do |direction|
        clause = column.split(", ").map { |part| "#{part} #{direction.upcase} NULLS LAST" }.join(", ")
        [ "#{key} #{direction}", "#{clause}, created_at DESC, id" ]
      end
    end.to_h.freeze, T::Hash[String, String])

    class Filters < T::Struct
      const :query, T.nilable(String), default: nil
      const :states, T::Array[OptimizedVersion::State], default: []
      const :origin, T.nilable(OptimizedVersion::Origin), default: nil
      const :reasons, T::Array[OptimizedVersion::Reason], default: []
      const :interrupted, T::Boolean, default: false
      # Only versions whose file nobody has played in this many days.
      const :unplayed_days, T.nilable(Integer), default: nil
      const :sort, String, default: "queue"
      const :direction, String, default: "asc"
    end

    sig { params(filters: Filters).void }
    def initialize(filters)
      @filters = filters
    end

    # Every filter applies outside, after the queue is numbered over the
    # whole queue — so a search still says a file is fourth in line, not
    # first of what matched.
    sig { returns(T.untyped) }
    def scope
      outer = OptimizedVersion.from(OptimizedVersion.joins(JOINS).select(COLUMNS), :optimized_versions)
      outer = outer.where(state: @filters.states.map(&:serialize)) if @filters.states.any?
      origin = @filters.origin
      outer = outer.where(origin: origin.serialize) if origin
      outer = outer.where(reason: @filters.reasons.map(&:serialize)) if @filters.reasons.any?
      outer = outer.where(interruptions: 1..) if @filters.interrupted
      if (days = @filters.unplayed_days)
        outer = outer.where("last_played_at IS NULL OR last_played_at < ?", days.days.ago)
      end
      if (query = @filters.query.presence)
        outer = outer.where("title ILIKE :q OR file_path ILIKE :q", q: "%#{OptimizedVersion.sanitize_sql_like(query)}%")
      end
      direction = @filters.direction == "desc" ? "desc" : "asc"
      outer.order(Arel.sql(ORDERS.fetch("#{@filters.sort} #{direction}", ORDERS.fetch("queue asc"))))
    end
  end
end
