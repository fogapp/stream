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
        merge_references("Show", { source.id => target.id })
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

      merge_episodes(Episode.where(season_id: season.id).order(:id).to_a, target, twin)
      Extra.where(owner: season).update_all(owner_id: twin.id) # rubocop:disable Rails/SkipsModelValidations
      merge_references("Season", { season.id => twin.id })
      Season.find(season.id).destroy!
    end
    private_class_method :merge_season

    # The same numbered episode (or, for a dated show, the same air date)
    # in the target is its twin; one with no twin simply moves. The twins
    # are read once for the season, and what names a merged episode is
    # re-pointed a table at a time (merge_references) before any of them
    # goes.
    sig { params(episodes: T::Array[Episode], target: Show, season: Season).void }
    def self.merge_episodes(episodes, target, season)
      return if episodes.empty?

      # By each episode's own season number, as its twin was always looked for.
      numbered = T.let({}, T::Hash[[ Integer, Integer ], Episode])
      dated = T.let({}, T::Hash[[ Integer, Date ], Episode])
      Episode.where(show_id: target.id, season_number: episodes.map(&:season_number).uniq).each do |candidate|
        if (number = candidate.episode_number)
          numbered[[ candidate.season_number, number ]] ||= candidate
        elsif (date = candidate.air_date)
          dated[[ candidate.season_number, date ]] ||= candidate
        end
      end
      pairs = T.let([], T::Array[[ Episode, Episode ]])
      episodes.each do |episode|
        number = episode.episode_number
        date = episode.air_date
        twin = if number then numbered[[ episode.season_number, number ]]
        elsif date then dated[[ episode.season_number, date ]]
        end
        if twin.nil?
          episode.update!(show: target, season: season)
          # A later one of the same number (or date) is its twin now.
          if number then numbered[[ episode.season_number, number ]] = episode
          elsif date then dated[[ episode.season_number, date ]] ||= episode
          end
          next
        end
        pairs << [ episode, twin ]
      end
      return if pairs.empty?

      merge_editions(pairs)
      merge_watch_states(pairs)
      # A twin two episodes merge into takes them one after the other, so
      # the second sees what the first brought (one round per twin).
      rounds = T.let([], T::Array[T::Hash[String, String]])
      pairs.each do |from, to|
        round = rounds.find { |each| !each.value?(to.id) } || (rounds << {}).last
        T.must(round)[from.id] = to.id
      end
      rounds.each { |round| merge_references("Episode", round) }
      Episode.where(id: pairs.map { |from, _| from.id }).order(:id).each(&:destroy!)
    end
    private_class_method :merge_episodes

    # Each merged episode's files join its twin's, but a file the twin
    # already has isn't held twice.
    sig { params(pairs: T::Array[[ Episode, Episode ]]).void }
    def self.merge_editions(pairs)
      twins = pairs.to_h { |from, to| [ from.id, to ] }
      turn = twins.keys.each_with_index.to_h
      held = Edition.where(playable_type: "Episode", playable_id: twins.values.map(&:id)).pluck(:playable_id, :media_file_id).to_set
      # In the order merging them one at a time took them: by episode, then row.
      Edition.where(playable_type: "Episode", playable_id: twins.keys).to_a.sort_by { |row| [ turn.fetch(row.playable_id.to_s), row.id ] }.each do |edition|
        twin = twins.fetch(edition.playable_id.to_s)
        if held.include?([ twin.id, edition.media_file_id ])
          edition.destroy!
        else
          edition.update!(playable: twin)
          held << [ twin.id, edition.media_file_id ]
        end
      end
    end
    private_class_method :merge_editions

    # One row per profile: finished if either was, the plays of both, and
    # the place from whichever was watched last.
    sig { params(pairs: T::Array[[ Episode, Episode ]]).void }
    def self.merge_watch_states(pairs)
      twins = pairs.to_h { |from, to| [ from.id, to ] }
      kept_by = WatchState.where(playable_type: "Episode", playable_id: twins.values.map(&:id)).to_a
        .index_by { |state| [ state.profile_id, state.playable_id.to_s ] }
      turn = twins.keys.each_with_index.to_h
      WatchState.where(playable_type: "Episode", playable_id: twins.keys).to_a.sort_by { |row| [ turn.fetch(row.playable_id.to_s), row.id ] }.each do |state|
        to = twins.fetch(state.playable_id.to_s)
        kept = kept_by[[ state.profile_id, to.id ]]
        if kept.nil?
          state.update!(playable: to)
          kept_by[[ state.profile_id, to.id ]] = state
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

    # Every pair at once (old id => survivor's id), a table at a time:
    # what clashes with the survivor's own is destroyed, the rest re-pointed
    # in one statement. Survivors are distinct within a call.
    sig { params(type: String, pairs: T::Hash[String, String]).void }
    def self.merge_references(type, pairs)
      REFERENCES.each do |model, name, unique_by|
        type_column = :"#{name}_type"
        id_column = :"#{name}_id"
        rows = model.unscoped.where(type_column => type, id_column => pairs.keys)
        if unique_by
          kept = model.unscoped.where(type_column => type, id_column => pairs.values)
          taken = kept.pluck(id_column, *unique_by).to_set { |key| Array(key).map(&:to_s) }
          clashing = rows.select(:id, id_column, *unique_by).to_a.select do |row|
            taken.include?([ pairs.fetch(row.public_send(id_column).to_s), *unique_by.map { |column| row.public_send(column).to_s } ])
          end
          model.unscoped.where(id: clashing.map(&:id)).order(:id).each(&:destroy!) if clashing.any?
        end
        repoint(model, type_column, id_column, rows, pairs)
      end
    end
    private_class_method :merge_references

    sig do
      params(model: T.class_of(ApplicationRecord), type_column: Symbol, id_column: Symbol, rows: T.untyped, pairs: T::Hash[String, String]).void
    end
    def self.repoint(model, type_column, id_column, rows, pairs)
      if pairs.size == 1
        rows.update_all(id_column => pairs.values.first) # rubocop:disable Rails/SkipsModelValidations
        return
      end

      # CASE col WHEN from THEN to … ELSE col END, built as Arel so no SQL is
      # spliced from strings; ELSE gives the literals the column's own type.
      column = model.arel_table[id_column]
      repointed = pairs.reduce(Arel::Nodes::Case.new(column)) do |node, (from, to)|
        node.when(Arel::Nodes.build_quoted(from)).then(Arel::Nodes.build_quoted(to))
      end.else(column)
      rows.update_all(id_column => repointed) # rubocop:disable Rails/SkipsModelValidations
    end
    private_class_method :repoint

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
