# typed: strict
# frozen_string_literal: true

module Catalog
  # The rules a smart collection (Viewing::SmartCollection) and a Grid
  # block (Stations::Source) both narrow films and shows by, and answer the
  # same way. Each applies its own others — and its own meaning of
  # "unwatched": the viewer's for a collection, the household's for a
  # channel. A rule that isn't there (nil, or no values) narrows nothing.
  module TitleFilter
    extend T::Sig

    # Libraries, genres (any of them) and a rating floor.
    sig { params(scope: T.untyped, rules: T::Hash[String, T.untyped]).returns(T.untyped) }
    def self.call(scope, rules)
      libraries = Array(rules["library_ids"])
      genres = Array(rules["genres"])
      scope = scope.where(library_id: libraries) if libraries.any?
      scope = scope.where(scope.klass.overlap(:genres, genres)) if genres.any?
      scope = scope.where(scope.klass.arel_table[:vote_average].gteq(rules["min_rating"])) unless rules["min_rating"].nil?
      scope
    end

    # The title's own year, from and to (inclusive).
    sig { params(scope: T.untyped, rules: T::Hash[String, T.untyped]).returns(T.untyped) }
    def self.years(scope, rules)
      scope = scope.where(year: rules["year_from"]..) unless rules["year_from"].nil?
      scope = scope.where(year: ..rules["year_to"]) unless rules["year_to"].nil?
      scope
    end
  end
end
