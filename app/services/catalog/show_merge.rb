# typed: strict
# frozen_string_literal: true

module Catalog
  # Two folders of one show matched separately ("Bluey" and "Bluey (2018)"):
  # the later show's folders, seasons and episodes join the one that already
  # had the title, and it goes. An episode both copies hold becomes one
  # episode with an edition from each, as a second copy of a film does; what
  # anyone did with either — watch state, ratings, playlists, a channel's
  # schedule — follows to the survivor.
  module ShowMerge
    extend T::Sig

    sig { params(source: Show, target: Show).returns(Show) }
    def self.call(source, target)
      raise ArgumentError, "a show can't merge into itself" if source.id == target.id

      Show.transaction do
        Show.unscoped.where(id: [ source.id, target.id ]).order(:id).lock.load
        ShowFolder.unscoped.where(show_id: source.id).update_all(show_id: target.id) # rubocop:disable Rails/SkipsModelValidations
        source.seasons.to_a.each { |season| merge_season(season, target) }
        merge_references("Show", source.id, target.id)
        Airing.where(series_key: source.id).update_all(series_key: target.id) # rubocop:disable Rails/SkipsModelValidations
        ShowPreference.where(show_id: source.id).where(profile_id: ShowPreference.where(show_id: target.id).select(:profile_id)).delete_all
        ShowPreference.where(show_id: source.id).update_all(show_id: target.id) # rubocop:disable Rails/SkipsModelValidations
        rewrite_station_rules(source.id, target.id)
        Activity.record(source: "library", event: "show.merged", subject: target, household_id: target.household_id,
          summary: "#{source.title} (#{source.folder}) joined #{target.title} (#{target.folder})")
        Show.unscoped.find(source.id).destroy!
      end
      target
    end

    sig { params(season: Season, target: Show).void }
    def self.merge_season(season, target)
      twin = target.seasons.find_by(season_number: season.season_number)
      if twin.nil?
        season.update!(show: target)
        Episode.where(season_id: season.id).update_all(show_id: target.id) # rubocop:disable Rails/SkipsModelValidations
        return
      end

      Episode.where(season_id: season.id).find_each { |episode| merge_episode(episode, target, twin) }
      Extra.where(owner: season).update_all(owner_id: twin.id) # rubocop:disable Rails/SkipsModelValidations
      merge_references("Season", season.id, twin.id)
      Season.find(season.id).destroy!
    end
    private_class_method :merge_season

    # The same numbered episode (or, for a dated show, the same air date)
    # in the target is its twin; one with no twin simply moves.
    sig { params(episode: Episode, target: Show, season: Season).void }
    def self.merge_episode(episode, target, season)
      twins = Episode.where(show_id: target.id, season_number: episode.season_number)
      twin = if episode.episode_number
        twins.find_by(episode_number: episode.episode_number)
      elsif episode.air_date
        twins.find_by(air_date: episode.air_date, episode_number: nil)
      end
      if twin.nil?
        episode.update!(show: target, season: season)
        return
      end

      Edition.where(playable: episode).find_each do |edition|
        if Edition.exists?(media_file_id: edition.media_file_id, playable: twin)
          edition.destroy!
        else
          edition.update!(playable: twin)
        end
      end
      merge_watch_states(episode, twin)
      merge_references("Episode", episode.id, twin.id)
      Episode.find(episode.id).destroy!
    end
    private_class_method :merge_episode

    # One row per profile: finished if either was, the plays of both, and
    # the place from whichever was watched last.
    sig { params(from: Episode, to: Episode).void }
    def self.merge_watch_states(from, to)
      WatchState.where(playable: from).find_each do |state|
        kept = WatchState.find_by(profile_id: state.profile_id, playable: to)
        if kept.nil?
          state.update!(playable: to)
          next
        end

        later = [ state, kept ].max_by { |row| row.last_watched_at || Time.zone.at(0) }
        kept.update!(completed_at: [ state.completed_at, kept.completed_at ].compact.max,
          play_count: state.play_count + kept.play_count, last_watched_at: T.must(later).last_watched_at,
          position_seconds: T.must(later).position_seconds, duration_seconds: T.must(later).duration_seconds,
          media_file_id: T.must(later).media_file_id, hidden_from_continue: T.must(later).hidden_from_continue)
        state.destroy!
      end
    end
    private_class_method :merge_watch_states

    # Every polymorphic row naming the old record names the survivor; where
    # the survivor already has its own (one rating per profile, one poster),
    # the survivor's wins.
    REFERENCES = T.let([
      [ Artwork, :owner, %i[kind] ],
      [ CollectionItem, :item, %i[collection_id] ],
      [ PlaylistItem, :item, %i[playlist_id] ],
      [ Rating, :rateable, %i[profile_id] ],
      [ ProfileTag, :taggable, %i[profile_id] ],
      [ ProfileExclusion, :excludable, %i[profile_id] ],
      [ ProfileNotice, :subject, %i[profile_id] ],
      [ Trailer, :owner, [] ],
      [ Extra, :owner, nil ],
      [ Airing, :playable, nil ],
      [ PlaybackSession, :playable, nil ],
      [ OfflineDownload, :playable, nil ],
      [ TraktChange, :item, nil ],
      [ ActivityEntry, :subject, nil ]
    ].freeze, T::Array[[ T.class_of(ApplicationRecord), Symbol, T.nilable(T::Array[Symbol]) ]])

    sig { params(type: String, from: String, to: String).void }
    def self.merge_references(type, from, to)
      REFERENCES.each do |model, name, unique_by|
        rows = model.unscoped.where("#{name}_type": type, "#{name}_id": from)
        if unique_by
          kept = model.unscoped.where("#{name}_type": type, "#{name}_id": to)
          taken = unique_by.empty? ? (kept.exists? ? Set[[]] : Set.new) : kept.pluck(*unique_by).to_set { |key| Array(key) }
          rows.find_each { |row| row.destroy! if taken.include?(unique_by.map { |column| row.public_send(column) }) }
        end
        rows.update_all("#{name}_id": to) # rubocop:disable Rails/SkipsModelValidations
      end
    end
    private_class_method :merge_references

    sig { params(from: String, to: String).void }
    def self.rewrite_station_rules(from, to)
      StationBlock.where("source->'show_ids' ? :id OR source->'exclude_show_ids' ? :id", id: from).find_each do |block|
        source = block.source.dup
        %w[show_ids exclude_show_ids].each do |key|
          source[key] = Array(source[key]).map { |id| id == from ? to : id }.uniq if source[key]
        end
        block.update!(source: source)
      end
    end
    private_class_method :rewrite_station_rules
  end
end
