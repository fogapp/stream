# typed: strict
# frozen_string_literal: true

module Stations
  # What a block of a channel draws from (PROPOSAL §7.7), cleaned from a form
  # into what's stored. Picked titles (shows, films, collections, YouTube
  # channels) narrow the mix to themselves; every other rule narrows further.
  # Networks choose shows and studios choose films, so a channel with only
  # networks airs no films unless studios are given too. Likewise a video
  # answers only the rules it can (channel, library, upload year, length):
  # genres, keywords, networks, studios, a rating floor or people leave
  # videos out, and a rating ceiling lets them in only with unrated titles.
  # Unwatched leaves out what any profile (or any of the picked ones) has
  # finished — the household's lineup, so nobody's in particular unless
  # asked.
  module Rules
    extend T::Sig

    KINDS = T.let(%w[movie episode video].freeze, T::Array[String])
    # A block that doesn't say: the library's films and shows, not every
    # video the household has pulled.
    DEFAULT_KINDS = T.let(%w[movie episode].freeze, T::Array[String])
    UUID = /\A[0-9a-f-]{36}\z/
    LISTS = T.let(%w[genres exclude_genres networks studios keywords exclude_keywords].freeze, T::Array[String])
    IDS = T.let(%w[show_ids exclude_show_ids movie_ids exclude_movie_ids collection_ids channel_ids library_ids person_ids
      unwatched_profile_ids].freeze, T::Array[String])

    sig { params(raw: T.untyped).returns(T::Hash[String, T.untyped]) }
    def self.normalize(raw)
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h.to_h : raw
      raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
      int = ->(value) { value.to_s.match?(/\A\d+\z/) ? value.to_i : nil }
      bool = ->(value) { ActiveModel::Type::Boolean.new.cast(value) || false }
      kinds = Array(raw["kinds"]).map(&:to_s) & KINDS
      rules = T.let({ "kinds" => kinds.presence || DEFAULT_KINDS.dup }, T::Hash[String, T.untyped])
      IDS.each { |key| rules[key] = Array(raw[key]).map(&:to_s).grep(UUID).uniq.first(500) }
      # Picked channels would narrow shows and films to none without videos.
      rules.delete("channel_ids") unless rules.fetch("kinds").include?("video")
      unwatched = bool.call(raw["unwatched"])
      rules.delete("unwatched_profile_ids") unless unwatched
      LISTS.each { |key| rules[key] = Array(raw[key]).map { |value| value.to_s.strip }.compact_blank.uniq.first(30) }
      rules.merge(
        "year_from" => int.call(raw["year_from"]), "year_to" => int.call(raw["year_to"]),
        "min_rating" => raw["min_rating"].to_s.match?(/\A\d+(\.\d+)?\z/) ? raw["min_rating"].to_f.clamp(0.0, 10.0) : nil,
        "max_rating_age" => int.call(raw["max_rating_age"])&.clamp(0, 21),
        "allow_unrated" => raw.key?("allow_unrated") ? bool.call(raw["allow_unrated"]) : true,
        "min_minutes" => int.call(raw["min_minutes"]), "max_minutes" => int.call(raw["max_minutes"]),
        "include_specials" => bool.call(raw["include_specials"]),
        "unwatched" => unwatched || nil
      ).compact.reject { |_, value| value == [] }
    end
  end
end
