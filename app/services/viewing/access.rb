# typed: strict
# frozen_string_literal: true

module Viewing
  # What the watching profile may see (PROPOSAL §7.4), applied wherever the
  # catalog is read: its libraries, its rating ceiling (unrated titles only
  # if allowed), and, when curated, only what's tagged for it. A tag also
  # lets a title past the ceiling. What the profile has hidden from itself
  # (ProfileExclusion) is out whatever else says. Without a profile (jobs,
  # scripts) or with an unrestricted one that hides nothing, nothing changes.
  module Access
    extend T::Sig

    sig { returns(T.nilable(Profile)) }
    def self.profile
      profile = Current.profile
      profile.is_a?(Profile) && (profile.restricted? || profile.excludes_anything?) ? profile : nil
    end

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.movies(scope) = titles(scope, "Movie")

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.shows(scope) = titles(scope, "Show")

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.episodes(scope)
      return scope if profile.nil?

      scope.where(show_id: shows(Show.all).select(:id))
    end

    # Channels have no ratings: a ceiling hides them unless unrated titles
    # are allowed or the channel is tagged.
    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.channels(scope)
      viewer = profile
      return scope if viewer.nil?

      scope = unhidden(in_libraries(scope, viewer), viewer, "Channel")
      tagged = tagged_ids(viewer, "Channel")
      return scope.where(id: tagged) if viewer.curated
      return scope if viewer.max_rating_age.nil? || viewer.allow_unrated

      scope.where(id: tagged)
    end

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.videos(scope)
      return scope if profile.nil?

      scope.where(channel_id: channels(Channel.all).select(:id))
    end

    # Home videos: by library, and — curated or rating-limited without
    # unrated allowed — only those in albums tagged for the profile.
    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.clips(scope)
      viewer = profile
      return scope if viewer.nil?

      scope = in_libraries(scope, viewer)
      return scope if !viewer.curated && (viewer.max_rating_age.nil? || viewer.allow_unrated)

      scope.where(id: AlbumClip.where(album_id: tagged_ids(viewer, "Album")).select(:clip_id))
    end

    # Cameras and web streams (PROPOSAL §7.8): titles like any other — their
    # library, their rating, tags and hiding. A team's MLB.tv stream is in
    # no library and has no rating: Baseball is everyone's.
    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.live_streams(scope)
      return scope if profile.nil?

      titles(scope, "LiveStream").or(scope.where.not(mlb_team_id: nil))
    end

    # An extra is whatever its title is: a film's trailer goes where the film
    # may, a season's scene where its show may. One that belongs to nothing
    # is anyone's.
    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.extras(scope)
      return scope if profile.nil?

      visible = shows(Show.all).select(:id)
      scope.where(owner_id: nil)
        .or(scope.where(owner_type: "Movie", owner_id: movies(Movie.all).select(:id)))
        .or(scope.where(owner_type: "Show", owner_id: visible))
        .or(scope.where(owner_type: "Season", owner_id: Season.where(show_id: visible).select(:id)))
    end

    # Collections a profile can come across: a household's own always, and
    # TMDB's only with something in them it can play — one the household has
    # none of, or none this profile may see, isn't a shelf to it. Applies
    # with or without a profile: what can be played is everyone's question.
    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.collections(scope)
      held = CollectionItem.where(item_type: "Movie", item_id: Catalog.watchable_movies.select(:id))
        .or(CollectionItem.where(item_type: "Show", item_id: Catalog.watchable_shows.select(:id)))
      scope.where.not(kind: Collection::Kind::Tmdb.serialize).or(scope.where(id: held.select(:collection_id)))
    end

    # Grid channels (PROPOSAL §7.7): one lineup for the household, but a
    # restricted profile sees a channel only while everything on its
    # schedule from now on is something it may see.
    sig { params(scope: T.untyped, now: ActiveSupport::TimeWithZone).returns(T.untyped) }
    def self.stations(scope, now: Time.current)
      return scope if profile.nil?

      # A stream's channel shows only to a profile that may see the stream.
      scope = scope.where(live_stream_id: nil).or(scope.where(live_stream_id: live_streams(LiveStream.all).select(:id)))
      # Only these channels' airings, so (station_id, ends_at) serves it.
      ahead = Airing.where(station_id: scope.select(:id)).where("ends_at > ?", now)
      barred = ahead.where(playable_type: "Movie").where.not(playable_id: movies(Movie.all).select(:id))
        .or(ahead.where(playable_type: "Episode").where.not(playable_id: episodes(Episode.all).select(:id)))
        .or(ahead.where(playable_type: "Video").where.not(playable_id: videos(Video.all).select(:id)))
        .or(ahead.where(playable_type: "LiveStream").where.not(playable_id: live_streams(LiveStream.all).select(:id)))
        .or(ahead.where(playable_type: "Extra").where.not(playable_id: extras(Extra.all).select(:id)))
      scope.where.not(id: barred.select(:station_id))
    end

    # One title, for a detail page or pressing Play.
    sig { params(playable: T.untyped).returns(T::Boolean) }
    def self.allows?(playable)
      return true if profile.nil?

      case playable
      when Movie then movies(Movie.where(id: playable.id)).exists?
      when Show then shows(Show.where(id: playable.id)).exists?
      when Episode then episodes(Episode.where(id: playable.id)).exists?
      when Video then videos(Video.where(id: playable.id)).exists?
      when Channel then channels(Channel.where(id: playable.id)).exists?
      when Clip then clips(Clip.where(id: playable.id)).exists?
      when LiveStream then live_streams(LiveStream.where(id: playable.id)).exists?
      when Station then stations(Station.where(id: playable.id)).exists?
      when Extra then extras(Extra.where(id: playable.id)).exists?
      else true
      end
    end

    # The ones of `playables` the profile may see, in their order, in one
    # query per kind rather than one per title.
    sig do
      type_parameters(:P).params(playables: T::Array[T.type_parameter(:P)]).returns(T::Array[T.type_parameter(:P)])
    end
    def self.permitted(playables)
      return playables if profile.nil? || playables.empty?

      allowed = playables.group_by { |playable| T.unsafe(playable).class }.each_with_object(Set.new) do |(klass, rows), seen|
        scope = BY_CLASS[klass.name.to_s]
        if scope
          ids = rows.map { |row| T.unsafe(row).id }
          T.unsafe(self).public_send(scope, T.unsafe(klass).where(id: ids)).pluck(:id).each { |id| seen << [ klass.name, id ] }
        else
          rows.each { |row| seen << [ klass.name, T.unsafe(row).id ] if allows?(row) }
        end
      end
      playables.select { |playable| allowed.include?([ T.unsafe(playable).class.name, T.unsafe(playable).id ]) }
    end

    BY_CLASS = T.let({
      "Movie" => :movies, "Show" => :shows, "Episode" => :episodes, "Video" => :videos, "Channel" => :channels,
      "Clip" => :clips, "LiveStream" => :live_streams, "Station" => :stations, "Extra" => :extras
    }.freeze, T::Hash[String, Symbol])
    private_constant :BY_CLASS

    sig { params(scope: T.untyped, type: String).returns(T.untyped) }
    def self.titles(scope, type)
      viewer = profile
      return scope if viewer.nil?

      scope = unhidden(in_libraries(scope, viewer), viewer, type)
      tagged = tagged_ids(viewer, type)
      return scope.where(id: tagged) if viewer.curated

      ceiling = viewer.max_rating_age
      return scope if ceiling.nil?

      table = scope.klass.arel_table
      allowed = table[:rating_age].lteq(ceiling)
      allowed = allowed.or(table[:rating_age].eq(nil)) if viewer.allow_unrated
      scope.where(allowed.or(table[:id].in(tagged.arel)))
    end
    private_class_method :titles

    sig { params(scope: T.untyped, viewer: Profile).returns(T.untyped) }
    def self.in_libraries(scope, viewer)
      viewer.library_ids.any? ? scope.where(library_id: viewer.library_ids) : scope
    end
    private_class_method :in_libraries

    sig { params(scope: T.untyped, viewer: Profile, type: String).returns(T.untyped) }
    def self.unhidden(scope, viewer, type)
      return scope unless viewer.excludes_anything?

      scope.where.not(id: ProfileExclusion.where(profile_id: viewer.id, excludable_type: type).select(:excludable_id))
    end
    private_class_method :unhidden

    sig { params(viewer: Profile, type: String).returns(T.untyped) }
    def self.tagged_ids(viewer, type)
      ProfileTag.where(profile_id: viewer.id, taggable_type: type).select(:taggable_id)
    end
    private_class_method :tagged_ids
  end
end
