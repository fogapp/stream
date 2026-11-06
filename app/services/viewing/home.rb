# typed: strict
# frozen_string_literal: true

module Viewing
  # The home screen (PROPOSAL §7.1): a hero, then hubs in the order this
  # profile chose — by default Continue watching, Next up, New in each
  # YouTube library, Recently added in each TV library, then the rest. A
  # TV library's row is the episodes themselves, so what arrived plays
  # from Home — until a show brings a batch of them at once (a season, a
  # whole series), which stands in the row as the show. The hero takes a
  # show's new episodes as one arrival ("4 new episodes").
  class Home
    extend T::Sig

    HUB_SIZE = 20
    # How many of each source (Continue watching, Next up, new films, new
    # shows) may take a turn at the top of the page.
    HERO_EACH = 3
    # Episodes added this close to a show's latest count as one arrival.
    ARRIVAL_WINDOW = T.let(7.days, ActiveSupport::Duration)
    # An arrival this many episodes or more is one card in Recently added,
    # the show's, rather than a run of episodes that fills the row.
    BATCH_SIZE = 4

    # One episode's file landing: [show id, episode id, season, number, added at].
    Landing = T.type_alias { [ String, String, Integer, T.nilable(Integer), ActiveSupport::TimeWithZone ] }

    Card = T.type_alias { T::Hash[Symbol, T.untyped] }

    class Hub < T::Struct
      const :key, String
      const :title, String
      const :kind, String
      const :items, T::Array[T::Hash[Symbol, T.untyped]]
    end

    # A hub still to be carded: the page is primed once, with all of them.
    class Row < T::Struct
      const :key, String
      const :title, String
      const :kind, String
      const :items, T::Array[Cards::Title]
    end

    class Arrival < T::Struct
      const :show, Show
      const :label, String
      const :at, ActiveSupport::TimeWithZone
      # What came within ARRIVAL_WINDOW of `at`, and the show's episodes
      # from before it.
      const :batch, T::Array[Landing]
      const :earlier, T::Array[Landing]

      extend T::Sig

      sig { returns(T::Boolean) }
      def collapsed? = batch.size >= BATCH_SIZE

      # The one season it all came in, when the show had other episodes
      # already; a new show, or several seasons, open on the show itself.
      sig { returns(T.nilable(Integer)) }
      def season
        seasons = batch.map { |row| row[2] }.uniq
        seasons.first if seasons.size == 1 && earlier.any?
      end
    end

    # One title that may take the top of the page, and what Play plays.
    class HeroPick < T::Struct
      const :title, T.any(Movie, Show)
      const :play, T.any(Movie, Episode)
      const :label, String
      const :subtitle, T.nilable(String)
      const :overview, T.nilable(String), default: nil
    end

    sig { params(profile: Profile, random: Random).void }
    def initialize(profile, random: Random.new)
      @profile = profile
      @random = random
      @cards = T.let(Cards.new(profile), Cards)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def call
      in_progress = continue_watching
      continuing = T.let(in_progress.map(&:playable), T::Array[T.any(Movie, Episode, Video)])
      libraries = Library.order(:name).to_a
      movies_by_library = libraries.select { |library| library.kind == "movies" }
        .to_h { |library| [ library.id, Catalog.watchable_movies.where(library: library).order(created_at: :desc).limit(HUB_SIZE).to_a ] }
      show_libraries = libraries.select { |library| library.kind == "shows" }
      arrivals_by_library = show_libraries.to_h { |library| [ library.id, arrivals(library) ] }
      recent_by_library = arrivals_by_library.transform_values { |list| recently_added(list) }
      videos_by_library = libraries.select { |library| library.kind == "channels" }.to_h do |library|
        [ library.id, Channels::Catalog.watchable_videos(Video.where(library: library)).order(created_at: :desc).limit(HUB_SIZE)
          .includes(:channel).to_a ]
      end

      movies = movies_by_library.values.flatten
      arrived = arrivals_by_library.values.flatten
      newest = arrived.max_by(HERO_EACH, &:at)
      following = shows_to_follow(exclude: continuing.grep(Episode).filter_map(&:show_id))
      # Next up's row and where the newest arrivals start, in one go.
      picks = NextUp.for_shows((following + newest.map(&:show)).uniq, @profile)
      next_up = following.filter_map { |show| (pick = picks[show.id]) && pick.started_show ? pick.episode : nil }
      subscribed = subscription_videos
      pinned = pinned_rows
      because = because_rows
      clips = HomeVideos::Catalog.on_this_day(HomeVideos::Catalog.watchable).order(captured_at: :desc).limit(HUB_SIZE).to_a
      # Everything on the page at once: a title's artwork, progress and
      # length asked for once, not once for each row it's in.
      @cards.prime(continuing + next_up + recent_by_library.values.flatten.grep(Episode) + arrived.map(&:show) + movies +
        videos_by_library.values.flatten + subscribed + (pinned + because).flat_map(&:items) + clips, states: in_progress)

      # Continue watching and Next up, then what's new from YouTube and in
      # the TV libraries, then everything else.
      hubs = [
        Hub.new(key: "continue_watching", title: "Continue watching", kind: "continue",
          items: continuing.map { |playable| @cards.card(playable) }),
        Hub.new(key: "next_up", title: "Next up", kind: "wide", items: next_up.map { |episode| @cards.card(episode) })
      ]
      libraries.select { |library| library.kind == "channels" }.each do |library|
        hubs << Hub.new(key: "recently_added:#{library.id}", title: "New in #{library.name}", kind: "videos",
          items: videos_by_library.fetch(library.id, []).map { |video| @cards.card(video) })
      end
      show_libraries.each do |library|
        hubs << Hub.new(key: "recently_added:#{library.id}", title: "Recently added in #{library.name}", kind: "wide",
          items: recent_by_library.fetch(library.id, []).map do |item|
            case item
            when Episode then @cards.card(item)
            when Arrival then @cards.card(item.show).merge(arrival: item.label, season_number: item.season)
            else T.absurd(item)
            end
          end)
      end
      hubs.concat(pinned.map { |row| hub(row) })
      hubs << Hub.new(key: "subscriptions", title: "New from your subscriptions", kind: "videos",
        items: subscribed.map { |video| @cards.card(video) })
      libraries.select { |library| library.kind == "movies" }.each do |library|
        hubs << Hub.new(key: "recently_added:#{library.id}", title: "Recently added in #{library.name}", kind: "poster",
          items: movies_by_library.fetch(library.id, []).map { |movie| @cards.card(movie) })
      end
      hubs.concat(because.map { |row| hub(row) })
      # Home videos have On this day rather than a Recently added row.
      hubs << Hub.new(key: "on_this_day", title: "On this day", kind: "clips", items: clips.map { |clip| @cards.card(clip) })

      ordered = arrange(hubs)
      hidden = Array(@profile.home_layout["hidden"])
      heroes = heroes(continuing, next_up, movies, newest, picks)
      {
        profile: { id: @profile.id, name: @profile.name, color: @profile.color },
        # A different one each visit, so the top of the page isn't always
        # the same title. The web keeps its own pick across refetches.
        hero: heroes.sample(random: @random),
        heroes: heroes,
        hubs: ordered.reject { |hub| hidden.include?(hub.key) || hub.items.empty? }.map(&:serialize),
        layout: ordered.map { |hub| { key: hub.key, title: hub.title, hidden: hidden.include?(hub.key) } }
      }
    end

    private

    sig { params(row: Row).returns(Hub) }
    def hub(row)
      Hub.new(key: row.key, title: row.title, kind: row.kind, items: row.items.map { |item| @cards.card(item) })
    end

    # What this profile is partway through, latest first. Asked of the
    # database whole, so what can't be played or can't be seen doesn't take
    # a place in the row.
    sig { returns(T::Array[WatchState]) }
    def continue_watching
      states = WatchState.in_progress.where(profile: @profile)
      states.where(playable_type: "Movie", playable_id: Catalog.watchable_movies.select(:id))
        .or(states.where(playable_type: "Episode", playable_id: Access.episodes(Episode.where(id: Catalog.readable_ids("Episode"))).select(:id)))
        .or(states.where(playable_type: "Video", playable_id: Channels::Catalog.watchable_videos.select(:id)))
        .order(last_watched_at: :desc).limit(HUB_SIZE).includes(playable: %i[show channel]).to_a
    end

    # Collections and playlists the profile pinned (PROPOSAL §7.1), each a
    # row of what's in it that this profile can watch.
    sig { returns(T::Array[Row]) }
    def pinned_rows
      Array(@profile.home_layout["pinned"]).filter_map do |pin|
        case pin["kind"]
        when "collection"
          collection = Collection.find_by(id: pin["id"].to_s)
          next if collection.nil?

          Row.new(key: "pinned_collection:#{collection.id}", title: collection.title, kind: "poster",
            items: Catalog.watchable_titles(collection.items).first(HUB_SIZE))
        when "playlist"
          playlist = Playlist.find_by(id: pin["id"].to_s, profile: @profile)
          next if playlist.nil?

          Row.new(key: "pinned_playlist:#{playlist.id}", title: playlist.title, kind: "continue", items: playlist.items.first(HUB_SIZE))
        end
      end
    end

    # Hubs in the profile's order; any it hasn't placed (a new library)
    # keep their default place after the ones it has.
    sig { params(hubs: T::Array[Hub]).returns(T::Array[Hub]) }
    def arrange(hubs)
      order = Array(@profile.home_layout["order"])
      placed = order.filter_map { |key| hubs.find { |hub| hub.key == key } }
      placed + (hubs - placed)
    end

    # The playable editions of a library's episodes, joined to their episode
    # and show.
    sig { params(library: Library).returns(T.untyped) }
    def episode_editions(library)
      Catalog.readable_editions.where(playable_type: "Episode")
        .joins("JOIN episodes ON episodes.id = editions.playable_id JOIN shows ON shows.id = episodes.show_id")
        .where(shows: { library_id: library.id })
        # Before choosing the newest: a show this profile can't see mustn't
        # arrive on its Home, nor take a place in the row.
        .where(shows: { id: Access.shows(Show.all).select(:id) })
    end

    # A TV library's Recently added: its newest episodes, each once, newest
    # first, except that a show's batch (BATCH_SIZE or more at once) is the
    # one Arrival. A run of one show's episodes (a few that arrived
    # together) reads E01, E02… rather than in the order the scan found them.
    sig { params(arrivals: T::Array[Arrival]).returns(T::Array[T.any(Episode, Arrival)]) }
    def recently_added(arrivals)
      # Every show past these arrived before each of them did, so the row
      # is made from these alone.
      entries = arrivals.flat_map do |arrival|
        landings = arrival.earlier + (arrival.collapsed? ? [] : arrival.batch)
        landings.map { |row| [ row[4], row[1] ] } + (arrival.collapsed? ? [ [ arrival.at, arrival ] ] : [])
      end
      picked = entries.sort_by { |at, _| at }.reverse.first(HUB_SIZE).map(&:last)
      episodes = Episode.where(id: picked.grep(String)).includes(:show).index_by(&:id)
      items = picked.filter_map { |item| item.is_a?(Arrival) ? item : episodes[item] }
      items.chunk_while { |a, b| a.is_a?(Episode) && b.is_a?(Episode) && a.show_id == b.show_id }
        .flat_map { |run| run.sort_by { |item| item.is_a?(Episode) ? [ item.season_number, item.episode_number || 0 ] : [ 0, 0 ] } }
    end

    # The shows in a library that got something new, newest first, each
    # labelled with what arrived.
    sig { params(library: Library).returns(T::Array[Arrival]) }
    def arrivals(library)
      episodes = episode_editions(library)
      latest = episodes.group("episodes.show_id").maximum("editions.created_at")
      ids = latest.sort_by { |_, at| at }.reverse.first(HUB_SIZE).map(&:first)
      return [] if ids.empty?

      # Newest first, so an episode with two files keeps the later one.
      rows = T.let(episodes.where(episodes: { show_id: ids }).order("editions.created_at DESC")
        .pluck("episodes.show_id", "episodes.id", "episodes.season_number", "episodes.episode_number", "editions.created_at")
        .uniq { |row| row[1] }, T::Array[Landing])
      by_show = rows.group_by(&:first)
      Show.where(id: ids).index_by(&:id).values_at(*ids).compact.map do |show|
        at = latest.fetch(show.id)
        all = by_show.fetch(show.id, [])
        batch, earlier = all.partition { |row| row[4] >= at - ARRIVAL_WINDOW }
        Arrival.new(show: show, at: at, label: arrival_label(batch, all), batch: batch, earlier: earlier)
      end
    end

    sig { params(batch: T::Array[Landing], all: T::Array[Landing]).returns(String) }
    def arrival_label(batch, all)
      return "New show" if batch.size == all.size && all.size > 1
      if batch.size == 1
        row = T.must(batch.first)
        return format("New episode · S%<season>02dE%<episode>02d", season: row[2], episode: row[3].to_i)
      end

      seasons = batch.map { |row| row[2] }.uniq
      if seasons.size == 1 && all.count { |row| row[2] == seasons.first } == batch.size
        return "Season #{seasons.first} added"
      end

      "#{batch.size} new episodes"
    end

    # What may take the top of the page: a few each of what you were
    # watching, what's next in the shows you're following, and the newest
    # films and shows — once per title, in that order.
    sig do
      params(continuing: T::Array[T.any(Movie, Episode, Video)], next_up: T::Array[Episode], movies: T::Array[Movie],
        newest: T::Array[Arrival], starts: T::Hash[String, T.nilable(NextUp::Pick)]).returns(T::Array[Card])
    end
    def heroes(continuing, next_up, movies, newest, starts)
      picks = T.let([], T::Array[HeroPick])
      continuing.each do |playable|
        case playable
        when Movie then picks << HeroPick.new(title: playable, play: playable, label: "Continue watching", subtitle: playable.year&.to_s)
        when Episode
          show = playable.show
          picks << HeroPick.new(title: show, play: playable, label: "Continue watching",
            subtitle: "#{playable.code} · #{playable.title}", overview: playable.overview) if show
        end
      end
      picks = picks.first(HERO_EACH)
      next_up.first(HERO_EACH).each do |episode|
        show = episode.show
        picks << HeroPick.new(title: show, play: episode, label: "Next up", subtitle: "#{episode.code} · #{episode.title}",
          overview: episode.overview) if show
      end
      movies.max_by(HERO_EACH, &:created_at).each { |movie| picks << HeroPick.new(title: movie, play: movie, label: "Just added", subtitle: movie.year&.to_s) }
      newest.each do |arrival|
        episode = starts[arrival.show.id]&.episode
        picks << HeroPick.new(title: arrival.show, play: episode, label: arrival.label, subtitle: arrival.show.year&.to_s) if episode
      end

      picks = picks.uniq { |pick| pick.title.id }
      trailers = Trailer.where(owner: picks.map(&:title)).index_by(&:owner_id)
      picks.map do |pick|
        hero_json(pick.title, pick.play, @cards.state(pick.play), label: pick.label, subtitle: pick.subtitle, overview: pick.overview,
          trailer: trailers[pick.title.id])
      end
    end

    sig do
      params(title: T.any(Movie, Show), play: T.any(Movie, Episode), state: T.nilable(WatchState), label: String,
        subtitle: T.nilable(String), overview: T.nilable(String), trailer: T.nilable(Trailer)).returns(Card)
    end
    def hero_json(title, play, state, label:, subtitle:, overview:, trailer:)
      {
        kind: title.is_a?(Movie) ? "movie" : "show", id: title.id, title: title.title, subtitle: subtitle, label: label,
        overview: overview.presence || title.overview, images: @cards.images(title),
        play: { kind: play.is_a?(Movie) ? "movie" : "episode", id: play.id },
        progress: CatalogSerializer.progress(state),
        resume_at: state&.resume_seconds,
        # Plays, muted, behind the hero (PROPOSAL §7.1).
        trailer: (url = Trailers.url(trailer)) && { url: url, name: trailer&.name }
      }
    end

    # "Because you watched Heat": the nearest unwatched titles to the last
    # two this profile finished (PROPOSAL §7.1).
    sig { returns(T::Array[Row]) }
    def because_rows
      finished = Recommendations::Similar.finished_ids(@profile)
      Recommendations::Similar.recently_finished(@profile).filter_map do |title|
        like = Recommendations::Similar.to(title, exclude: finished)
        next if like.size < 3

        Row.new(key: "because:#{title.id}", title: "Because you watched #{title.title}", kind: "poster", items: like)
      end
    end

    # The newest videos this profile hasn't finished, from its subscriptions.
    sig { returns(T::Array[Video]) }
    def subscription_videos
      channels = @profile.channel_subscriptions.select(:channel_id)
      finished = WatchState.finished(@profile, "Video").select(:playable_id)
      Channels::Catalog.watchable_videos(Video.where(channel_id: channels)).where.not(id: finished)
        .order(Arel.sql("upload_date DESC NULLS LAST, created_at DESC")).limit(HUB_SIZE).includes(:channel).to_a
    end

    # Shows the profile finished an episode of recently, most recently
    # watched first — but not shows already in Continue watching.
    sig { params(exclude: T::Array[String]).returns(T::Array[Show]) }
    def shows_to_follow(exclude:)
      recent = WatchState.finished(@profile, "Episode")
        .where(last_watched_at: 90.days.ago..).order(last_watched_at: :desc).limit(100).pluck(:playable_id)
      show_of = Episode.where(id: recent).pluck(:id, :show_id).to_h
      show_ids = recent.filter_map { |episode_id| show_of[episode_id] }.uniq - exclude
      show_ids -= dismissed_shows(show_ids)
      shows = Access.shows(Show.where(id: show_ids)).index_by(&:id)
      show_ids.filter_map { |id| shows[id] }.first(HUB_SIZE)
    end

    # Shows dismissed from Next up: their latest watch state is hidden
    # (WatchState.hide_from_home).
    sig { params(show_ids: T::Array[String]).returns(T::Array[String]) }
    def dismissed_shows(show_ids)
      WatchState.joins("JOIN episodes ON episodes.id = watch_states.playable_id")
        .where(profile: @profile, playable_type: "Episode", episodes: { show_id: show_ids })
        .order(Arel.sql("episodes.show_id, watch_states.last_watched_at DESC NULLS LAST"))
        .pluck(Arel.sql("DISTINCT ON (episodes.show_id) episodes.show_id"), :hidden_from_continue)
        .filter_map { |show_id, hidden| show_id if hidden }
    end
  end
end
