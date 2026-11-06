# typed: strict
# frozen_string_literal: true

module Viewing
  # The episode to play next in a show (PROPOSAL §7.1, Plex's On Deck): the
  # one in progress if there is one, else the first unwatched episode after
  # the furthest one watched, else the first episode. Only episodes with a
  # file count; specials only when nothing else is left.
  module NextUp
    extend T::Sig

    class Pick < T::Struct
      const :episode, Episode
      const :state, T.nilable(WatchState)
      # Whether the profile has started this show at all: a first episode is
      # "Play", a later one is "Play next".
      const :started_show, T::Boolean
    end

    sig { params(show: Show, profile: Profile).returns(T.nilable(Pick)) }
    def self.for(show, profile) = for_shows([ show ], profile)[show.id]

    # The pick for each of several shows, in a fixed number of queries
    # however many there are (Home's Next up row).
    sig { params(shows: T::Array[Show], profile: Profile).returns(T::Hash[String, T.nilable(Pick)]) }
    def self.for_shows(shows, profile)
      by_id = shows.index_by(&:id)
      episodes = Episode.where(show_id: by_id.keys, id: Catalog.readable_ids("Episode")).reorder(:season_number, :episode_number, :air_date).to_a
      # Each already knows its show; asking again would be a query apiece.
      episodes.each { |episode| episode.association(:show).target = by_id.fetch(episode.show_id) }
      states = Catalog.watch_index(profile, episodes)
      grouped = episodes.group_by(&:show_id)
      shows.to_h { |show| [ show.id, pick(grouped.fetch(show.id, []), states) ] }
    end

    # The pick among these episodes, in order, from this profile's states
    # (ShowProgress hands it every episode, file or not).
    sig { params(episodes: T::Array[Episode], states: T::Hash[String, WatchState]).returns(T.nilable(Pick)) }
    def self.pick(episodes, states)
      return nil if episodes.empty?

      in_progress = episodes.select { |episode| (state = states[episode.id]) && !state.completed? && state.position_seconds.positive? }
        .max_by { |episode| states.fetch(episode.id).last_watched_at || Time.at(0) }
      return Pick.new(episode: in_progress, state: states[in_progress.id], started_show: true) if in_progress

      regular = episodes.reject { |episode| episode.season_number.zero? }
      furthest = regular.rindex { |episode| states[episode.id]&.completed? }
      candidates = furthest ? regular.drop(furthest + 1) : regular
      nxt = candidates.find { |episode| !states[episode.id]&.completed? }
      nxt ||= regular.find { |episode| !states[episode.id]&.completed? } if furthest.nil?
      return nil if nxt.nil?

      Pick.new(episode: nxt, state: states[nxt.id], started_show: !furthest.nil?)
    end

    sig { params(show: Show).returns(ActiveRecord::Relation) }
    def self.available(show)
      show.episodes.where(id: Catalog.readable_ids("Episode")).reorder(:season_number, :episode_number, :air_date)
    end
  end
end
