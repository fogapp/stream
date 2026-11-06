# typed: strict
# frozen_string_literal: true

module Viewing
  # The queries the viewing surface is built from (PROPOSAL §7.1–7.2). A
  # title shows up only once some file of it is readable: a library of
  # missing or broken files is an admin's problem, not a poster wall.
  module Catalog
    extend T::Sig

    sig { returns(T.untyped) }
    def self.readable_editions = Edition.readable

    # The ids of one kind of title with a file that plays, for a subquery.
    sig { params(type: String).returns(T.untyped) }
    def self.readable_ids(type) = readable_editions.where(playable_type: type).select(:playable_id)

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.watchable_movies(scope = Movie.all)
      Access.movies(scope.where(id: readable_ids("Movie")))
    end

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.watchable_shows(scope = Show.all)
      Access.shows(scope.where(id: Episode.where(id: readable_ids("Episode")).select(:show_id)))
    end

    # Changes whenever a household's playable set does: a file becomes
    # readable (count up), goes missing or broken (count down), or an edition
    # takes another's place (newest edition). Household-wide, not per
    # profile: a change a profile can't see costs it one refetch.
    sig { params(household: Household).returns(String) }
    def self.version(household)
      count, newest = readable_editions.where(media_files: { household_id: household.id })
        .pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(editions.created_at)"))
      "#{count}.#{newest&.to_f}"
    end

    # The movies and shows among `titles` that have something to play and
    # that the profile may see, in their order: two queries in all.
    sig { params(titles: T::Array[T.any(Movie, Show)]).returns(T::Array[T.any(Movie, Show)]) }
    def self.watchable_titles(titles)
      movie_ids = watchable_movies(Movie.where(id: titles.grep(Movie).map(&:id))).pluck(:id).to_set
      show_ids = watchable_shows(Show.where(id: titles.grep(Show).map(&:id))).pluck(:id).to_set
      titles.select { |title| title.is_a?(Movie) ? movie_ids.include?(title.id) : show_ids.include?(title.id) }
    end

    # A title's extras that can be played.
    sig { params(scope: T.untyped).returns(T::Array[Extra]) }
    def self.playable_extras(scope)
      scope.joins(:media_file).merge(MediaFile.playable).preload(:media_file).to_a
    end

    # Watch states for a page of playables, keyed by playable id.
    sig { params(profile: Profile, playables: T::Array[T.any(Movie, Episode, Video, Clip)]).returns(T::Hash[String, WatchState]) }
    def self.watch_index(profile, playables)
      return {} if playables.empty?

      WatchState.where(profile: profile, playable: playables).index_by(&:playable_id)
    end

    # Unwatched episodes-with-files per show, in one grouped query.
    sig { params(profile: Profile, shows: T::Array[Show]).returns(T::Hash[String, Integer]) }
    def self.unwatched_counts(profile, shows)
      return {} if shows.empty?

      unwatched_episodes(profile).where(show_id: shows.map(&:id)).group(:show_id).count
    end

    # Only the shows with an episode the profile hasn't finished, as a
    # scope, so a grid filters before it pages.
    sig { params(scope: T.untyped, profile: Profile).returns(T.untyped) }
    def self.with_unwatched(scope, profile)
      scope.where(id: unwatched_episodes(profile).select(:show_id))
    end

    sig { params(profile: Profile).returns(T.untyped) }
    def self.unwatched_episodes(profile)
      watched = WatchState.finished(profile, "Episode").select(:playable_id)
      Episode.where(id: readable_ids("Episode")).where.not(id: watched)
    end
    private_class_method :unwatched_episodes

    # Titles by their ids elsewhere (Hook's lookup: GET /shows?tmdb_id=):
    # each column's comma-separated ids, several columns OR'd. A filter
    # asked for with no usable id finds nothing rather than everything.
    INTEGER_IDS = T.let(%i[tmdb_id tvdb_id].freeze, T::Array[Symbol])

    sig { params(scope: T.untyped, filters: T::Hash[Symbol, String]).returns(T.untyped) }
    def self.with_external_ids(scope, filters)
      return scope if filters.empty?

      table = scope.klass.arel_table
      conditions = filters.filter_map do |column, raw|
        ids = raw.split(",").map(&:strip).reject(&:empty?)
        ids = ids.grep(/\A\d{1,9}\z/).map(&:to_i) if INTEGER_IDS.include?(column)
        ids.any? ? table[column].in(ids) : nil
      end
      return scope.none if conditions.empty?

      scope.where(conditions.reduce { |all, condition| all.or(condition) })
    end

    SORTS = T.let({
      "title" => "sort_title ASC", "year" => "year DESC NULLS LAST, sort_title ASC",
      "added" => "created_at DESC", "rating" => "vote_average DESC NULLS LAST, sort_title ASC"
    }.freeze, T::Hash[String, String])

    sig { params(scope: T.untyped, sort: T.nilable(String), query: T.nilable(String)).returns(T.untyped) }
    def self.browse(scope, sort:, query:)
      scope = scope.where("unaccent(title) ILIKE unaccent(?)", "%#{ActiveRecord::Base.sanitize_sql_like(query)}%") if query.present?
      scope.order(Arel.sql(SORTS.fetch(sort.to_s, SORTS.fetch("title"))))
    end

    # Where each letter starts in a grid sorted by title, for the alphabet
    # beside it: a title files under its first letter or digit, accents
    # aside, and anything that isn't A–Z under "#".
    sig { params(sort_titles: T::Array[String]).returns(T::Array[[ String, Integer ]]) }
    def self.letters(sort_titles)
      starts = T.let({}, T::Hash[String, Integer])
      sort_titles.each_with_index do |title, index|
        first = ActiveSupport::Inflector.transliterate(title)[/[[:alnum:]]/].to_s.upcase
        starts[first.match?(/\A[A-Z]\z/) ? first : "#"] ||= index
      end
      starts.sort
    end
  end
end
