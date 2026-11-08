# typed: strict
# frozen_string_literal: true

module Trakt
  # Brings a linked profile's Trakt into Stream (PROPOSAL §7.4): plays from
  # other apps, resume points, stars and the watchlist. Trakt's
  # last_activities says what changed since the last pull, so a quiet
  # account costs one request.
  #
  # The newer view wins, as with Plex: a Trakt play Stream already has (the
  # scrobble of a Stream play, or an echo of one it sent) changes nothing,
  # and a resume point older than Stream's is left alone. Stars and the
  # watchlist are compared with what Trakt held last time (synced_keys), so a
  # removal on either side is honoured; a title with a change still waiting
  # to go to Trakt is left for that change to settle. Unwatching on Trakt
  # isn't carried over: Trakt keeps no record of when it happened.
  #
  # Writes go straight to the rows, never through Trakt::Outbox, so nothing
  # pulled is sent back. The first pull also sends Stream's own history,
  # stars and Watch later that Trakt doesn't have.
  class Pull
    extend T::Sig

    Item = T.type_alias { T.any(Movie, Episode, Show) }

    # A Trakt play this close to one Stream has is that play.
    SAME_PLAY = T.let(10.minutes, ActiveSupport::Duration)
    # A Trakt resume point this close to Stream's last report is that report.
    SAME_PAUSE = T.let(5.minutes, ActiveSupport::Duration)
    HISTORY_PAGE = 100
    HISTORY_PAGES = 50

    sig { params(account: TraktAccount).void }
    def initialize(account)
      @account = account
      @profile = T.let(T.must(account.profile), Profile)
      @counts = T.let({}, T::Hash[String, Integer])
      @catalog = T.let(nil, T.nilable(Catalog))
      # The profile's states of the batch in hand (a response, a page),
      # and the longest file of each: read for the batch, not per row.
      @states = T.let({}, T::Hash[[ String, String ], WatchState])
      @durations = T.let({}, T::Hash[[ String, String ], T.nilable(Float)])
    end

    sig { params(api: Api).returns(T::Hash[String, Integer]) }
    def call(api = Api.for(@account))
      @api = T.let(api, T.nilable(Api))
      activities = T.cast(api.get("/sync/last_activities"), T::Hash[String, T.untyped])
      before = @account.last_activities
      first = before.blank?
      keys = @account.synced_keys.dup
      Current.set(profile: @profile) do
        watched = first ? pull_all_watched : pull_history(before, activities)
        pull_playback if first || changed?(before, activities, "movies", "paused_at") || changed?(before, activities, "episodes", "paused_at")
        if first || %w[movies shows episodes].any? { |type| changed?(before, activities, type, "rated_at") }
          keys["ratings"] = pull_ratings(Array(keys["ratings"]), first: first)
        end
        if first || %w[movies episodes].any? { |type| changed?(before, activities, type, "watchlisted_at") }
          keys["watchlist"] = pull_watchlist(Array(keys["watchlist"]), first: first)
        end
        backfill_history(watched) if first
      end
      @account.update!(last_activities: activities, synced_keys: keys, last_synced_at: Time.current, last_error: nil, last_error_at: nil)
      TraktPushJob.perform_later(@account.id) if @account.trakt_changes.exists?
      record
      @counts
    end

    private

    sig { returns(Api) }
    def api = T.must(@api)

    # Read when a pull first has something to look up, inside its
    # Current.set (Viewing::Access): a quiet account costs one request.
    sig { returns(Catalog) }
    def catalog = @catalog ||= Catalog.new(@account.household_id)

    sig { params(before: T::Hash[String, T.untyped], now: T::Hash[String, T.untyped], type: String, key: String).returns(T::Boolean) }
    def changed?(before, now, type, key) = before.dig(type, key) != now.dig(type, key)

    # Everything Trakt counts as watched, on the first pull. Returns the keys
    # of what Trakt has, for the backfill.
    sig { returns(T::Set[String]) }
    def pull_all_watched
      seen = T.let(Set.new, T::Set[String])
      movies = Array(api.get("/sync/watched/movies")).filter_map { |row| (movie = catalog.movie(row["movie"])) && [ movie, row ] }
      batch(movies.map(&:first))
      movies.each do |movie, row|
        seen << Catalog.key(movie)
        watched(movie, time(row["last_watched_at"]), plays: row["plays"].to_i)
      end
      Array(api.get("/sync/watched/shows")).each do |row|
        episodes = T.let([], T::Array[[ Episode, T::Hash[String, T.untyped] ]])
        catalog.each_watched_episode(row) { |episode, detail| episodes << [ episode, detail ] }
        batch(episodes.map(&:first))
        episodes.each do |episode, detail|
          seen << Catalog.key(episode)
          watched(episode, time(detail["last_watched_at"]), plays: detail["plays"].to_i)
        end
      end
      seen
    end

    # Plays since the last pull.
    sig { params(before: T::Hash[String, T.untyped], now: T::Hash[String, T.untyped]).returns(T::Set[String]) }
    def pull_history(before, now)
      { "movies" => "movies", "episodes" => "episodes" }.each do |type, path|
        next unless changed?(before, now, type, "watched_at")

        since = before.dig(type, "watched_at")
        (1..HISTORY_PAGES).each do |page|
          rows = Array(api.get("/sync/history/#{path}?limit=#{HISTORY_PAGE}&page=#{page}#{since ? "&start_at=#{CGI.escape(since)}" : ''}"))
          items = rows.filter_map { |row| (item = catalog.item(row)).is_a?(Movie) || item.is_a?(Episode) ? [ item, row ] : nil }
          batch(items.map(&:first))
          items.each { |item, row| watched(item, time(row["watched_at"])) }
          break if rows.size < HISTORY_PAGE
        end
      end
      Set.new
    end

    # A play on Trakt: Stream's state moves to it unless Stream already has
    # it or has seen something newer.
    sig { params(playable: T.any(Movie, Episode), at: T.nilable(ActiveSupport::TimeWithZone), plays: T.nilable(Integer)).void }
    def watched(playable, at, plays: nil)
      return if at.nil? || at > 1.minute.from_now

      state = state_for(playable)
      completed = state.completed_at
      last = state.last_watched_at
      if completed && completed >= at - SAME_PLAY
        # Already known; the first pull may still bring a higher play count.
        state.update!(play_count: plays) if plays && plays > state.play_count
        return
      end
      # Stream has watched some of it since: that's the newer view.
      return if last && last > at

      state.assign_attributes(completed_at: at, last_watched_at: at, position_seconds: 0.0, hidden_from_continue: false,
        play_count: plays ? [ plays, state.play_count ].max : state.play_count + 1)
      state.save!
      count("watched")
    rescue ActiveRecord::RecordNotUnique
      # Made meanwhile (a play reported as this ran): read it again.
      @states.delete(key_of(playable))
      retry
    end

    # Resume points left by other apps.
    sig { void }
    def pull_playback
      %w[movies episodes].each do |type|
        items = Array(api.get("/sync/playback/#{type}"))
          .filter_map { |row| (item = catalog.item(row)).is_a?(Movie) || item.is_a?(Episode) ? [ item, row ] : nil }
        batch(items.map(&:first), durations: true)
        items.each { |item, row| paused(item, row["progress"].to_f, time(row["paused_at"])) }
      end
    end

    sig { params(playable: T.any(Movie, Episode), progress: Float, at: T.nilable(ActiveSupport::TimeWithZone)).void }
    def paused(playable, progress, at)
      return if at.nil? || progress >= WatchState::COMPLETE_AT * 100

      state = state_for(playable)
      last = [ state.last_watched_at, state.completed_at ].compact.max
      return if last && last >= at - SAME_PAUSE

      duration = state.duration_seconds || @durations.fetch(key_of(playable)) { playable.media_files.maximum(:duration_seconds) }
      return if duration.nil? || !duration.positive?

      position = duration * progress / 100
      return if position < WatchState::STARTED_AFTER

      # Picked up again elsewhere after it was finished: in progress again.
      state.assign_attributes(position_seconds: position, duration_seconds: duration, last_watched_at: at, completed_at: nil,
        hidden_from_continue: false)
      state.save!
      count("resumed")
    rescue ActiveRecord::RecordNotUnique
      @states.delete(key_of(playable))
      retry
    end

    # The batch about to be merged: the profile's states of it in one query
    # (and, for resume points, the longest file of each in another).
    sig { params(playables: T::Array[T.any(Movie, Episode)], durations: T::Boolean).void }
    def batch(playables, durations: false)
      @states = WatchState.index_for(@profile, playables)
      @durations = {}
      return unless durations && playables.any?

      longest = MediaFile.joins(:editions).where(editions: { playable: playables.uniq })
        .group("editions.playable_type", "editions.playable_id").maximum(:duration_seconds)
      playables.each { |playable| @durations[key_of(playable)] = longest[key_of(playable)] }
    end

    sig { params(playable: T.any(Movie, Episode)).returns(WatchState) }
    def state_for(playable)
      @states[key_of(playable)] ||= WatchState.find_or_initialize_by(profile: @profile, playable: playable)
    end

    sig { params(playable: T.any(Movie, Episode)).returns([ String, String ]) }
    def key_of(playable) = [ playable.class.polymorphic_name, playable.id ]

    # Stars both ways. Returns what Trakt holds now, for next time.
    sig { params(before: T::Array[String], first: T::Boolean).returns(T::Array[String]) }
    def pull_ratings(before, first:)
      held = T.let({}, T::Hash[String, [ Item, Integer, T.nilable(ActiveSupport::TimeWithZone) ]])
      %w[movies shows episodes].each do |type|
        Array(api.get("/sync/ratings/#{type}")).each do |row|
          item = catalog.item(row)
          held[Catalog.key(item)] = [ item, row["rating"].to_i, time(row["rated_at"]) ] if item
        end
      end
      waiting = waiting_keys(TraktChange::Action::RatingSet, TraktChange::Action::RatingRemove)
      mine = Rating.where(profile: @profile, rateable_type: %w[Movie Show Episode]).to_a.index_by { |rating| "#{rating.rateable_type}:#{rating.rateable_id}" }

      held.each do |key, (item, value, at)|
        next if waiting.include?(key) || !value.between?(1, 10)

        rating = mine[key]
        next if rating && (rating.value.round == value || (at && rating.rated_at >= at))

        (rating || Rating.new(profile: @profile, rateable: item)).update!(value: value.to_f, rated_at: at || Time.current)
        count("rated")
      end
      # Gone from Trakt since last time, and not changed here since: gone here too.
      synced = @account.last_synced_at
      (before - held.keys).each do |key|
        rating = mine[key]
        next if rating.nil? || waiting.include?(key) || (synced && rating.rated_at > synced)

        rating.destroy!
        count("unrated")
      end
      backfill_ratings(mine, held, waiting) if first
      held.keys
    end

    # The Trakt watchlist and Watch later, both ways. Shows on the Trakt
    # watchlist are left there: Watch later holds films and episodes.
    sig { params(before: T::Array[String], first: T::Boolean).returns(T::Array[String]) }
    def pull_watchlist(before, first:)
      held = T.let({}, T::Hash[String, T.any(Movie, Episode)])
      %w[movies episodes].each do |type|
        Array(api.get("/sync/watchlist/#{type}")).each do |row|
          item = catalog.item(row)
          held[Catalog.key(item)] = item if item.is_a?(Movie) || item.is_a?(Episode)
        end
      end
      playlist = Playlist.watch_later_for(@profile)
      saved = playlist.playlist_items.where(item_type: %w[Movie Episode]).to_a.index_by { |row| "#{row.item_type}:#{row.item_id}" }
      waiting = waiting_keys(TraktChange::Action::WatchlistAdd, TraktChange::Action::WatchlistRemove)

      last = playlist.playlist_items.maximum(:position).to_i
      held.each do |key, item|
        next if saved.key?(key) || waiting.include?(key)

        last += 1
        PlaylistItem.create!(playlist: playlist, item: item, position: last)
        count("saved")
      rescue ActiveRecord::RecordNotUnique
        next
      end
      (before - held.keys).each do |key|
        row = saved[key]
        next if row.nil? || waiting.include?(key)

        row.destroy!
        count("unsaved")
      end
      if first
        saved.each_value do |row|
          key = "#{row.item_type}:#{row.item_id}"
          Outbox.record(@profile.id, TraktChange::Action::WatchlistAdd, row.item, enqueue: false, account: @account) unless held.key?(key)
        end
      end
      held.keys
    end

    # The first pull: what Stream watched that Trakt doesn't know, one play each.
    sig { params(on_trakt: T::Set[String]).void }
    def backfill_history(on_trakt)
      WatchState.finished(@profile, %w[Movie Episode]).includes(:playable)
        .find_in_batches do |states|
          # An episode is named to Trakt by its show: loaded with the batch.
          ActiveRecord::Associations::Preloader.new(records: states.map(&:playable).grep(Episode), associations: :show).call
          states.each do |state|
            playable = state.playable
            next if playable.nil? || on_trakt.include?("#{state.playable_type}:#{state.playable_id}")

            Outbox.watched(@profile.id, playable, watched: true, at: T.must(state.completed_at), enqueue: false, account: @account)
            count("sent")
          end
        end
    end

    sig do
      params(mine: T::Hash[String, Rating], held: T::Hash[String, T.untyped], waiting: T::Set[String]).void
    end
    def backfill_ratings(mine, held, waiting)
      mine.each do |key, rating|
        next if waiting.include?(key)

        on_trakt = held[key]
        next if on_trakt && (on_trakt[1] == rating.value.round || (on_trakt[2] && on_trakt[2] >= rating.rated_at))

        Outbox.rated(@profile.id, rating.rateable, rating.value, enqueue: false, account: @account)
      end
    end

    # Titles with a change still on its way to Trakt.
    sig { params(actions: TraktChange::Action).returns(T::Set[String]) }
    def waiting_keys(*actions)
      @account.trakt_changes.where(action: actions.map(&:serialize)).pluck(:item_type, :item_id)
        .to_set { |type, id| "#{type}:#{id}" }
    end

    sig { params(value: T.untyped).returns(T.nilable(ActiveSupport::TimeWithZone)) }
    def time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    sig { params(what: String).void }
    def count(what)
      @counts[what] = @counts.fetch(what, 0) + 1
    end

    sig { void }
    def record
      return if @counts.empty?

      summary = @counts.map { |what, count| "#{count} #{what}" }.join(", ")
      Activity.record(source: "trakt", event: "trakt.pulled", subject: @account, household_id: @account.household_id,
        summary: "Trakt sync for #{@profile.name}: #{summary}")
    end
  end
end
