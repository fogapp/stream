# typed: strict
# frozen_string_literal: true

module Viewing
  # Global search (PROPOSAL §7.2): titles, episodes and people, forgiving
  # of accents and typos. A substring match always counts; otherwise
  # pg_trgm's word similarity ("severence" finds Severance). Only what can
  # be watched is found, as everywhere else on the viewing side.
  module Search
    extend T::Sig

    LIMIT = 8
    # How alike a misspelling must be to still count (0–1).
    THRESHOLD = 0.4

    Result = T.type_alias { T::Hash[Symbol, T::Array[T.untyped]] }

    sig { params(query: String).returns(Result) }
    def self.call(query)
      query = query.strip.first(100)
      return { movies: [], shows: [], episodes: [], people: [], collections: [], channels: [], videos: [], said: [], clips: [] } if query.length < 2

      movies = matching(Catalog.watchable_movies, Movie.arel_table[:title], query).to_a
      shows = matching(Catalog.watchable_shows, Show.arel_table[:title], query).to_a
      episodes = query.length < 3 ? [] : matching(watchable_episodes, Episode.arel_table[:title], query).includes(:show).to_a
      people = matching(Person.where(id: credited_person_ids), Person.arel_table[:name], query).to_a
      collections = matching(Access.collections(Collection.all), Collection.arel_table[:title], query).to_a
      channels = matching(Channel.where(id: Channels::Catalog.watchable_videos.select(:channel_id)), Channel.arel_table[:title], query).to_a
      videos = query.length < 3 ? [] : matching(Channels::Catalog.watchable_videos, Video.arel_table[:title], query).includes(:channel).to_a
      { movies: movies, shows: shows, episodes: episodes, people: people, collections: collections, channels: channels, videos: videos,
        said: said(query), clips: clips(query) }
    end

    sig { params(scope: T.untyped, column: Arel::Attributes::Attribute, query: String).returns(T.untyped) }
    def self.matching(scope, column, query)
      escaped = ActiveRecord::Base.sanitize_sql_like(query)
      text = unaccent(column)
      contains = text.matches(unaccent(Arel::Nodes.build_quoted("%#{escaped}%")))
      starts = text.matches(unaccent(Arel::Nodes.build_quoted("#{escaped}%")))
      likeness = Arel::Nodes::NamedFunction.new("word_similarity", [ unaccent(Arel::Nodes.build_quoted(query)), text ])
      scope
        .where(contains.or(likeness.gteq(THRESHOLD)))
        # Starts-with first, then contains, then by likeness.
        .order(Arel::Nodes::Grouping.new(starts).desc, Arel::Nodes::Grouping.new(contains).desc, likeness.desc, column.asc)
        .limit(LIMIT)
    end

    sig { params(node: T.any(Arel::Nodes::Node, Arel::Attributes::Attribute)).returns(Arel::Nodes::NamedFunction) }
    def self.unaccent(node)
      Arel::Nodes::NamedFunction.new("unaccent", [ node ])
    end
    private_class_method :unaccent
    private_class_method :matching

    # Home videos by where they were taken, what they say, or who's in them.
    sig { params(query: String).returns(T::Array[Clip]) }
    def self.clips(query)
      like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      named = HomePerson.where("unaccent(name) ILIKE unaccent(?)", like).select(:id)
      HomeVideos::Catalog.watchable
        .where("unaccent(coalesce(city, '')) ILIKE unaccent(:like) OR unaccent(coalesce(description, '')) ILIKE unaccent(:like)", like: like)
        .or(HomeVideos::Catalog.watchable.where(id: ClipPerson.where(home_person_id: named).select(:clip_id)))
        .order(captured_at: :desc).limit(LIMIT).to_a
    end

    SAID_LIMIT = 8

    # Where it was said (PROPOSAL §7.2): the best-matching line in each of
    # up to eight titles, with its time and the words around the match.
    sig { params(query: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.said(query)
      return [] if query.length < 3

      household_id = Current.household&.id
      return [] if household_id.nil?

      # Each file's best line, the best few files, and only then their
      # snippets: a highlight is dear, and a common word matches thousands
      # of lines. A few more than are shown, for what Access leaves out.
      sql = <<~SQL.squish
        WITH best AS (
          SELECT DISTINCT ON (media_file_id) media_file_id, start_seconds, text,
            ts_rank(tsv, websearch_to_tsquery('english', :query)) AS rank
          FROM transcript_lines
          WHERE tsv @@ websearch_to_tsquery('english', :query)
            AND media_file_id IN (SELECT id FROM media_files WHERE household_id = :household_id AND state = :state)
          ORDER BY media_file_id, rank DESC, start_seconds
        ), top AS (
          SELECT * FROM best ORDER BY rank DESC LIMIT :limit
        )
        SELECT media_file_id, start_seconds, rank,
          ts_headline('english', text, websearch_to_tsquery('english', :query), 'StartSel=<<, StopSel=>>, MaxWords=18, MinWords=8') AS snippet
        FROM top ORDER BY rank DESC
      SQL
      binds = { query: query, household_id: household_id, state: MediaFile::State::Probed.serialize, limit: SAID_LIMIT * 3 }
      rows = ActiveRecord::Base.connection.select_all(ActiveRecord::Base.sanitize_sql_array([ sql, binds ])).to_a
      editions = Viewing::Catalog.readable_editions.where(media_file_id: rows.map { |row| row["media_file_id"] }).includes(:playable)
        .index_by(&:media_file_id)
      found = rows.filter_map do |row|
        playable = editions[row["media_file_id"]]&.playable
        [ row, playable ] if playable.is_a?(Movie) || playable.is_a?(Episode) || playable.is_a?(Video)
      end
      # An episode is titled by its show: loaded together, not one by one.
      episodes = found.map(&:last).grep(Episode)
      ActiveRecord::Associations::Preloader.new(records: episodes, associations: :show).call if episodes.any?
      allowed = Access.permitted(found.map(&:last)).to_set
      found.filter_map do |row, playable|
        { playable: playable, start: row["start_seconds"].to_f, snippet: row["snippet"].to_s } if allowed.include?(playable)
      end.first(SAID_LIMIT)
    end

    sig { returns(T.untyped) }
    def self.watchable_episodes
      Access.episodes(Episode.where(id: Catalog.readable_editions.where(playable_type: "Episode").select(:playable_id), show_id: Show.select(:id)))
    end

    # People credited on something this household can watch.
    sig { returns(T.untyped) }
    def self.credited_person_ids
      Credit.where(creditable_type: "Movie", creditable_id: Catalog.watchable_movies.select(:id))
        .or(Credit.where(creditable_type: "Show", creditable_id: Catalog.watchable_shows.select(:id)))
        .select(:person_id)
    end
  end
end
