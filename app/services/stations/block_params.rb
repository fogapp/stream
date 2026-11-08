# typed: strict
# frozen_string_literal: true

module Stations
  # A channel's programming as the editor sends it, top to bottom, cleaned
  # into what Station#replace_blocks! takes: at most 50 blocks, one base
  # block (the mix for when nothing else is on) at most, and each block's
  # source through Rules.normalize.
  module BlockParams
    extend T::Sig

    class Invalid < StandardError; end

    sig { params(raw: T.untyped).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.normalize(raw)
      blocks = Array(raw).map { |block| block.respond_to?(:to_unsafe_h) ? block.to_unsafe_h.to_h : {} }
      if blocks.count { |block| block["layer"].to_s == StationBlock::Layer::Base.serialize } > 1
        raise Invalid, "A channel has one mix for when nothing else is on"
      end

      int = ->(value) { value.to_s.match?(/\A\d+\z/) ? value.to_i : nil }
      blocks.first(50).map do |block|
        {
          layer: block["layer"].to_s, name: block["name"].to_s.strip.presence, days: int.call(block["days"]) || StationBlock::EVERY_DAY,
          start_minute: int.call(block["start_minute"]), end_minute: int.call(block["end_minute"]),
          starts_on: block["starts_on"].presence, ends_on: block["ends_on"].presence,
          source: Rules.normalize(block["source"]), ordering: block["ordering"].presence || "shuffle",
          marathon_length: int.call(block["marathon_length"]) || 3,
          loops: block.key?("loops") ? ActiveModel::Type::Boolean.new.cast(block["loops"]) || false : true
        }
      end
    end
  end
end
