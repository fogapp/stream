# typed: strict
# frozen_string_literal: true

module Recommendations
  # "More like this" and "Because you watched" (PROPOSAL §7.1): the nearest
  # titles by what they're made of, among what this profile may watch.
  module Similar
    extend T::Sig

    LIMIT = 12
    # Beyond this cosine distance, "like" is a stretch.
    MAX_DISTANCE = 0.85

    sig { params(title: T.any(Movie, Show), exclude: T::Array[String], limit: Integer).returns(T::Array[T.any(Movie, Show)]) }
    def self.to(title, exclude: [], limit: LIMIT)
      vector = title.embedding
      return [] if vector.nil?

      scope = if title.is_a?(Movie)
        Viewing::Catalog.watchable_movies(Movie.where.not(id: [ title.id, *exclude ]).where.not(embedding: nil))
      else
        Viewing::Catalog.watchable_shows(Show.where.not(id: [ title.id, *exclude ]).where.not(embedding: nil))
      end
      T.unsafe(scope).nearest_neighbors(:embedding, vector, distance: "cosine").limit(limit * 2).to_a
        .select { |candidate| T.unsafe(candidate).neighbor_distance.to_f <= MAX_DISTANCE }.first(limit)
    end

    # Related videos (PROPOSAL §5.4): the nearest by tags and words, among
    # what this profile may watch.
    sig { params(video: Video, exclude: T::Array[String], limit: Integer).returns(T::Array[Video]) }
    def self.videos(video, exclude: [], limit: LIMIT)
      vector = video.embedding
      return [] if vector.nil?

      scope = Channels::Catalog.watchable_videos(Video.where.not(id: [ video.id, *exclude ]).where.not(embedding: nil))
      T.unsafe(scope).nearest_neighbors(:embedding, vector, distance: "cosine").limit(limit * 2).includes(:channel).to_a
        .select { |candidate| T.unsafe(candidate).neighbor_distance.to_f <= MAX_DISTANCE }.first(limit)
    end

    # What this profile finished lately, newest first: movies, and the shows
    # of episodes.
    sig { params(profile: Profile, count: Integer).returns(T::Array[T.any(Movie, Show)]) }
    def self.recently_finished(profile, count: 2)
      states = WatchState.finished(profile).order(completed_at: :desc).limit(40).includes(:playable).to_a
      ActiveRecord::Associations::Preloader.new(records: states.map(&:playable).grep(Episode), associations: :show).call
      titles = states.filter_map do |state|
        playable = state.playable
        case playable
        when Movie then playable
        when Episode then playable.show
        end
      end
      # Two shows of one title (filed from two folders, not yet one) are
      # one thing to have watched.
      Viewing::Access.permitted(titles.uniq { |title| [ title.class.name, title.tmdb_id || title.id ] }.reject { |title| title.embedding.nil? }).first(count)
    end

    # Titles this profile has finished, not to be offered again.
    sig { params(profile: Profile).returns(T::Array[String]) }
    def self.finished_ids(profile)
      finished = WatchState.finished(profile)
      finished.where(playable_type: "Movie").pluck(:playable_id) +
        Episode.where(id: finished.where(playable_type: "Episode").select(:playable_id)).distinct.pluck(:show_id)
    end
  end
end
