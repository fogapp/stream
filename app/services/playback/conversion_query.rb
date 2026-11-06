# typed: strict
# frozen_string_literal: true

module Playback
  # The Playback page's Needs converting table: the files some recent
  # device would have to convert (Report.transcode_report, built whole and
  # cached), with how often they actually were converted for someone this
  # month, filtered and sorted in Ruby — the report is already in memory.
  class ConversionQuery
    extend T::Sig

    RECENT = T.let(30.days, ActiveSupport::Duration)

    # A row's optimize status: its version's state, or none.
    NONE = "none"

    SORTS = T.let(%w[title devices conversions last_converted_at size status].freeze, T::Array[String])

    class Filters < T::Struct
      const :query, T.nilable(String), default: nil
      # "none", or OptimizedVersion::State values.
      const :statuses, T::Array[String], default: []
      const :device, T.nilable(String), default: nil
      const :library_id, T.nilable(String), default: nil
      const :all_devices, T::Boolean, default: false
      const :sort, String, default: "conversions"
      const :direction, String, default: "desc"
    end

    sig { params(household: Household, filters: Filters).void }
    def initialize(household, filters)
      @household = household
      @filters = filters
    end

    # Every row the filters keep, in order, and what the filters can offer.
    sig { returns([ T::Array[T::Hash[Symbol, T.untyped]], T::Hash[Symbol, T.untyped] ]) }
    def call
      rows = Report.transcode_report(@household)
      converted = PlaybackSession.watched.where(method: PlaybackSession::Method::VideoTranscode.serialize, started_at: RECENT.ago..)
        .where(media_file_id: rows.pluck(:media_file_id)).group(:media_file_id)
      counts = converted.count
      lasts = converted.maximum(:started_at)
      libraries = Library.where(id: rows.pluck(:library_id).uniq).pluck(:id, :name).to_h
      rows = rows.map do |row|
        row.merge(library: row[:library_id] && { id: row[:library_id], name: libraries[row[:library_id]] },
          conversions: counts.fetch(row[:media_file_id], 0), last_converted_at: lasts[row[:media_file_id]],
          status: row[:optimized]&.dig(:state)&.serialize || NONE)
      end
      facets = {
        devices: rows.flat_map { |row| row[:devices].map { |device| device[:device] } }.uniq.sort,
        libraries: libraries.map { |id, name| { id: id, name: name } }.sort_by { |library| library[:name].to_s }
      }
      [ sort(rows.select { |row| keep?(row) }), facets ]
    end

    private

    sig { params(row: T::Hash[Symbol, T.untyped]).returns(T::Boolean) }
    def keep?(row)
      return false if @filters.statuses.any? && @filters.statuses.exclude?(row[:status])
      return false if @filters.device && row[:devices].none? { |device| device[:device] == @filters.device }
      return false if @filters.library_id && row[:library_id] != @filters.library_id
      return false if @filters.all_devices && !row[:all_devices]

      query = @filters.query.presence&.downcase
      return true unless query

      [ row[:title], row[:filename] ].compact.any? { |text| text.downcase.include?(query) }
    end

    # Ties fall back to the title, so the order is stable page to page.
    sig { params(rows: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def sort(rows)
      key = SORTS.include?(@filters.sort) ? @filters.sort : "conversions"
      by_title = rows.sort_by { |row| (row[:title] || row[:filename]).to_s.downcase }
      return @filters.direction == "desc" ? by_title.reverse : by_title if key == "title"

      # What has no value (never converted) sinks either way.
      present, absent = by_title.partition { |row| !value(row, key).nil? }
      sorted = present.each_with_index.sort_by { |row, index| [ value(row, key), index ] }.map(&:first)
      (@filters.direction == "desc" ? stable_reverse(sorted, key) : sorted) + absent
    end

    # Descending without turning ties around: ties keep title order.
    sig { params(rows: T::Array[T::Hash[Symbol, T.untyped]], key: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def stable_reverse(rows, key)
      rows.chunk_while { |a, b| value(a, key) == value(b, key) }.to_a.reverse.flatten(1)
    end

    sig { params(row: T::Hash[Symbol, T.untyped], key: String).returns(T.untyped) }
    def value(row, key)
      case key
      when "devices" then row[:devices].size
      when "conversions" then row[:conversions]
      when "last_converted_at" then row[:last_converted_at]
      when "size" then row[:size]
      when "status" then row[:status]
      end
    end
  end
end
