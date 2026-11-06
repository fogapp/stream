# typed: strict
# frozen_string_literal: true

module Viewing
  # Cards for a page of titles of any kind (PROPOSAL §7.1–7.2): everything a
  # card needs — artwork, this profile's watch states, what's left of a show,
  # a video's length — asked once for the whole page, however many rows a
  # title turns up in. `prime` with everything on the page, then `card` each.
  class Cards
    extend T::Sig

    Title = T.type_alias { T.any(Movie, Show, Episode, Video, Clip) }

    sig { params(profile: Profile).void }
    def initialize(profile)
      @profile = profile
      @images = T.let({}, ArtworkSerializer::Index)
      @watch = T.let({}, CatalogSerializer::WatchIndex)
      @unwatched = T.let({}, T::Hash[String, Integer])
      @durations = T.let({}, T::Hash[String, Float])
      @clips = T.let({}, T::Hash[String, T::Hash[Symbol, T.untyped]])
    end

    # Loads what the titles' cards need. `states`: watch states the caller
    # already has, not asked for again. `pictured`: anything else on the page
    # with artwork (people, collections), for `images`.
    sig { params(titles: T::Array[Title], states: T::Array[WatchState], pictured: T::Array[ApplicationRecord]).returns(T.self_type) }
    def prime(titles, states: [], pictured: [])
      titles = titles.uniq
      episodes = titles.grep(Episode)
      videos = titles.grep(Video)
      clips = titles.grep(Clip)
      states.each { |state| @watch[state.playable_id] = state }
      @images.merge!(ArtworkSerializer.index((titles - clips) + episodes.filter_map(&:show).uniq + videos.filter_map(&:channel).uniq + pictured))
      known = @watch.keys.to_set
      @watch.merge!(Catalog.watch_index(@profile, (titles.grep(Movie) + episodes + videos).reject { |title| known.include?(title.id) }))
      @unwatched.merge!(Catalog.unwatched_counts(@profile, titles.grep(Show)))
      @durations.merge!(Channels::Catalog.durations(videos))
      HomeVideos::Catalog.cards(@profile, clips).each { |card| @clips[card.fetch(:id)] = card }
      self
    end

    sig { params(title: Title).returns(T::Hash[Symbol, T.untyped]) }
    def card(title)
      case title
      when Movie then CatalogSerializer.movie_card(title, @images, @watch)
      when Show then CatalogSerializer.show_card(title, @images, @unwatched)
      when Episode then CatalogSerializer.episode_card(title, @images, @watch[title.id])
      when Video then CatalogSerializer.video_card(title, @images, @watch[title.id], duration: @durations[title.id])
      when Clip then @clips.fetch(title.id)
      else T.absurd(title)
      end
    end

    # What's known of this profile's progress through one title.
    sig { params(title: Title).returns(T.nilable(WatchState)) }
    def state(title) = @watch[title.id]

    # The artwork of everything primed, for what isn't a card.
    sig { params(owner: ApplicationRecord).returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
    def images(owner) = ArtworkSerializer.images(@images, owner)
  end
end
