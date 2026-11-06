# typed: strict
# frozen_string_literal: true

module Viewing
  # Where each of the household's profiles is in one show (Hook's
  # GET /shows/:id/progress): what it last watched, how much, and the
  # episode it would play next — over the show's whole catalog of episodes,
  # not only those with a file, because Hook fetches what comes next. Only
  # profiles that have watched something of it.
  module ShowProgress
    extend T::Sig

    class Row < T::Struct
      const :profile, Profile
      const :last_watched_at, T.nilable(ActiveSupport::TimeWithZone)
      const :watched_count, Integer
      # Nil before the show is started and once it is finished.
      const :next_up, T.nilable(Episode)
    end

    sig { params(show: Show).returns(T::Array[Row]) }
    def self.for(show)
      episodes = show.episodes.reorder(:season_number, :episode_number, :air_date).to_a
      by_profile = WatchState.where(playable_type: "Episode", playable_id: episodes.map(&:id)).to_a.group_by(&:profile_id)
      Profile.where(id: by_profile.keys).order(:position, :name).map do |profile|
        states = by_profile.fetch(profile.id).index_by(&:playable_id)
        pick = NextUp.pick(episodes, states)
        Row.new(
          profile: profile, last_watched_at: states.values.filter_map(&:last_watched_at).max,
          watched_count: states.values.count(&:completed?),
          next_up: pick&.started_show ? pick.episode : nil
        )
      end
    end
  end
end
