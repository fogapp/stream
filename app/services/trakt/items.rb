# typed: strict
# frozen_string_literal: true

module Trakt
  # Stream's titles as Trakt names them (PROPOSAL §7.4): by the ids both
  # sides agree on, and an episode by its show's ids with its season and
  # number, which holds even when the episode has no id of its own. A title
  # with no ids (still unmatched) can't be named, and is left out.
  module Items
    extend T::Sig

    class Entry < T::Struct
      const :item, T.any(Movie, Episode, Show)
      const :watched_at, T.nilable(ActiveSupport::TimeWithZone), default: nil
      const :rating, T.nilable(Integer), default: nil
    end

    sig { params(movie: Movie).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def self.movie_ids(movie)
      ids = { tmdb: movie.tmdb_id, imdb: movie.imdb_id.presence }.compact
      ids.empty? ? nil : ids
    end

    sig { params(show: Show).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def self.show_ids(show)
      ids = { tmdb: show.tmdb_id, tvdb: show.tvdb_id, imdb: show.imdb_id.presence }.compact
      ids.empty? ? nil : ids
    end

    # Whether Trakt could be told about this at all.
    sig { params(item: T.untyped).returns(T::Boolean) }
    def self.nameable?(item)
      case item
      when Movie then !movie_ids(item).nil?
      when Show then !show_ids(item).nil?
      when Episode
        show = item.show
        !item.episode_number.nil? && !show.nil? && !show_ids(show).nil?
      else false
      end
    end

    # A /sync body for these entries: { movies: [...], shows: [...] }.
    sig { params(entries: T::Array[Entry]).returns(T::Hash[Symbol, T::Array[T::Hash[Symbol, T.untyped]]]) }
    def self.body(entries)
      movies = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      shows = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      # show id => season number => episodes
      episodes = T.let({}, T::Hash[String, T::Hash[Integer, T::Array[T::Hash[Symbol, T.untyped]]]])
      by_show = T.let({}, T::Hash[String, Show])

      entries.each do |entry|
        item = entry.item
        next unless nameable?(item)

        case item
        when Movie then movies << extras(entry).merge(ids: movie_ids(item))
        when Show then shows << extras(entry).merge(ids: show_ids(item))
        when Episode
          show = T.must(item.show)
          by_show[show.id] = show
          ((episodes[show.id] ||= {})[item.season_number] ||= []) << extras(entry).merge(number: item.episode_number)
        else T.absurd(item)
        end
      end

      episodes.each do |show_id, seasons|
        shows << { ids: show_ids(T.must(by_show[show_id])),
                   seasons: seasons.map { |number, list| { number: number, episodes: list } } }
      end
      { movies: movies, shows: shows }.reject { |_key, list| list.empty? }
    end

    # What /scrobble takes for one movie or episode.
    sig { params(item: T.any(Movie, Episode)).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def self.scrobble_item(item)
      return nil unless nameable?(item)

      case item
      when Movie then { movie: { ids: movie_ids(item) } }
      when Episode
        { show: { ids: show_ids(T.must(item.show)) }, episode: { season: item.season_number, number: item.episode_number } }
      else T.absurd(item)
      end
    end

    sig { params(entry: Entry).returns(T::Hash[Symbol, T.untyped]) }
    def self.extras(entry)
      { watched_at: entry.watched_at&.utc&.iso8601, rating: entry.rating }.compact
    end
    private_class_method :extras
  end
end
