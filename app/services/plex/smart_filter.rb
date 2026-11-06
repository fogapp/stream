# typed: strict
# frozen_string_literal: true

module Plex
  # A Plex smart collection's saved filter, as Stream's smart-collection
  # rules (Viewing::SmartCollection) where they can say the same thing:
  # kind, genre, year and decade, unwatched, audience rating, recently
  # added, 4K and HDR, sort and limit. Anything else it asks for is listed
  # as not understood, and the importer brings a snapshot instead.
  module SmartFilter
    extend T::Sig

    class Result < T::Struct
      const :rules, T::Hash[String, T.untyped]
      const :not_understood, T::Array[String]

      extend T::Sig

      sig { returns(T::Boolean) }
      def complete? = not_understood.empty?
    end

    SORTS = T.let({ "addedAt" => "added", "titleSort" => "title", "title" => "title", "year" => "year",
                    "originallyAvailableAt" => "year", "rating" => "rating", "audienceRating" => "rating" }.freeze,
      T::Hash[String, String])
    # Plex's "ignore" keys: paging and presentation, not the filter.
    IGNORED = T.let(%w[includeGuids includeCollections includeExternalMedia X-Plex-Container-Start X-Plex-Container-Size].freeze,
      T::Array[String])

    # content: the smart collection's "content" (…/library/sections/1/all?…),
    # genres: the section's genre ids to names.
    sig { params(content: String, genres: T::Hash[String, String]).returns(Result) }
    def self.translate(content, genres:)
      query = content.split("?", 2)[1].to_s
      rules = T.let({}, T::Hash[String, T.untyped])
      # No filter at all would mean "everything": take the snapshot instead.
      unknown = T.let(query.empty? ? [ "content" ] : [], T::Array[String])
      query.split("&").each do |pair|
        key, value = pair.split("=", 2).map { |part| CGI.unescape(part.to_s) }
        key = key.to_s
        value = value.to_s
        # Plex writes operators into the key: "year>>" means year >=.
        name, operator = key.match(/\A([\w.]+?)(>>|<<|!)?\z/)&.captures || [ key, nil ]
        case [ name, operator ]
        in [ "type", nil ] then rules["kinds"] = value == "2" ? %w[show] : %w[movie]
        in [ "genre", nil ] then rules["genres"] = value.split(",").filter_map { |id| genres[id] || (id.match?(/\A\d+\z/) ? nil : id) }
        in [ "year", ">>" ] then rules["year_from"] = value.to_i
        in [ "year", "<<" ] then rules["year_to"] = value.to_i
        in [ "year", nil ] then rules["year_from"] = rules["year_to"] = value.to_i
        in [ "decade", nil ] then rules.merge!("year_from" => value.to_i, "year_to" => value.to_i + 9)
        in [ "unwatched", nil ] | [ "show.unwatched", nil ] then rules["unwatched"] = value == "1"
        in [ "audienceRating" | "rating", ">>" ] then rules["min_rating"] = value.to_f
        in [ "addedAt", ">>" ] then (days = relative_days(value)) ? rules["added_within_days"] = days : unknown << key
        in [ "resolution", nil ] then value == "4k" ? rules["uhd"] = true : unknown << key
        in [ "hdr", nil ] then rules["hdr"] = value == "1"
        in [ "sort", nil ] then (sort = SORTS[value.split(":").first.to_s]) ? rules["sort"] = sort : unknown << key
        in [ "limit", nil ] then rules["limit"] = value.to_i
        else unknown << key unless IGNORED.include?(key) || key.empty?
        end
      end
      unknown << "genre" if rules["genres"].is_a?(Array) && rules["genres"].empty?
      Result.new(rules: Viewing::SmartCollection.normalize(rules), not_understood: unknown.uniq)
    end

    # "-30d", "-2w", "-6m", "-1y" → days.
    sig { params(value: String).returns(T.nilable(Integer)) }
    def self.relative_days(value)
      match = value.match(/\A-(\d+)([dwmy])\z/)
      return nil if match.nil?

      match[1].to_i * { "d" => 1, "w" => 7, "m" => 30, "y" => 365 }.fetch(match[2].to_s)
    end
  end
end
