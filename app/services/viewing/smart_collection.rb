# typed: strict
# frozen_string_literal: true

module Viewing
  # A smart collection (PROPOSAL §7.2): a saved set of rules, worked out
  # when it's looked at — for whoever's looking (Access, and "unwatched"
  # means unwatched by them).
  module SmartCollection
    extend T::Sig

    SORTS = T.let(%w[added title year rating].freeze, T::Array[String])
    MAX = 200

    # Cleans a rules hash from a form into what's stored.
    sig { params(raw: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def self.normalize(raw)
      int = ->(value) { value.to_s.match?(/\A\d+\z/) ? value.to_i : nil }
      kinds = Array(raw["kinds"]).map(&:to_s) & %w[movie show]
      {
        "kinds" => kinds.presence || %w[movie show],
        "library_ids" => Array(raw["library_ids"]).map(&:to_s).grep(/\A[0-9a-f-]{36}\z/),
        "genres" => Array(raw["genres"]).map { |genre| genre.to_s.strip }.compact_blank.first(10),
        "year_from" => int.call(raw["year_from"]), "year_to" => int.call(raw["year_to"]),
        "min_rating" => raw["min_rating"].to_s.match?(/\A\d+(\.\d+)?\z/) ? raw["min_rating"].to_f.clamp(0.0, 10.0) : nil,
        "added_within_days" => int.call(raw["added_within_days"]),
        "unwatched" => ActiveModel::Type::Boolean.new.cast(raw["unwatched"]) || false,
        "uhd" => ActiveModel::Type::Boolean.new.cast(raw["uhd"]) || false,
        "hdr" => ActiveModel::Type::Boolean.new.cast(raw["hdr"]) || false,
        "sort" => SORTS.include?(raw["sort"].to_s) ? raw["sort"].to_s : "added",
        "limit" => (int.call(raw["limit"]) || 100).clamp(1, MAX)
      }.compact
    end

    sig { params(rules: T::Hash[String, T.untyped]).returns(T::Array[T.any(Movie, Show)]) }
    def self.items(rules)
      rules = normalize(rules)
      kinds = Array(rules["kinds"])
      limit = rules.fetch("limit").to_i
      found = T.let([], T::Array[T.any(Movie, Show)])
      found += filter(Catalog.watchable_movies, rules, "Movie").limit(limit).to_a if kinds.include?("movie")
      # Picture quality belongs to files, which only films have here.
      found += filter(Catalog.watchable_shows, rules, "Show").limit(limit).to_a if kinds.include?("show") && !rules["uhd"] && !rules["hdr"]
      sort(found, rules.fetch("sort").to_s).first(limit)
    end

    sig { params(scope: T.untyped, rules: T::Hash[String, T.untyped], type: String).returns(T.untyped) }
    def self.filter(scope, rules, type)
      table = scope.klass.arel_table
      scope = ::Catalog::TitleFilter.years(::Catalog::TitleFilter.call(scope, rules), rules)
      scope = scope.where(table[:created_at].gteq(rules["added_within_days"].to_i.days.ago)) if rules["added_within_days"]
      scope = unwatched(scope, type) if rules["unwatched"]
      if type == "Movie" && (rules["uhd"] || rules["hdr"])
        streams = MediaStream.where(kind: MediaStream::Kind::Video.serialize)
        streams = streams.where(height: 2000..) if rules["uhd"]
        streams = streams.where.not(hdr_format: nil) if rules["hdr"]
        scope = scope.where(id: Edition.where(playable_type: "Movie", media_file_id: streams.select(:media_file_id)).select(:playable_id))
      end
      order = { "added" => { created_at: :desc }, "title" => { sort_title: :asc }, "year" => { year: :desc }, "rating" => { vote_average: :desc } }
      scope.order(order.fetch(rules.fetch("sort").to_s))
    end
    private_class_method :filter

    sig { params(scope: T.untyped, type: String).returns(T.untyped) }
    def self.unwatched(scope, type)
      profile = Current.profile
      return scope unless profile.is_a?(Profile)

      if type == "Movie"
        scope.where.not(id: WatchState.finished(profile, "Movie").select(:playable_id))
      else
        # A show still has something unwatched in it.
        Catalog.with_unwatched(scope, profile)
      end
    end
    private_class_method :unwatched

    sig { params(items: T::Array[T.any(Movie, Show)], by: String).returns(T::Array[T.any(Movie, Show)]) }
    def self.sort(items, by)
      case by
      when "title" then items.sort_by(&:sort_title)
      when "year" then items.sort_by { |item| -item.year.to_i }
      when "rating" then items.sort_by { |item| -item.vote_average.to_f }
      else items.sort_by { |item| -item.created_at.to_f }
      end
    end
    private_class_method :sort
  end
end
