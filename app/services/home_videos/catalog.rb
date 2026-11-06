# typed: strict
# frozen_string_literal: true

module HomeVideos
  # The queries the home-video pages are built from (PROPOSAL §5.4).
  module Catalog
    extend T::Sig

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.watchable(scope = Clip.all)
      Viewing::Access.clips(scope.where(id: Viewing::Catalog.readable_ids("Clip")))
    end

    sig { params(profile: Profile, clips: T::Array[Clip]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.cards(profile, clips)
      return [] if clips.empty?

      images = ArtworkSerializer.index(clips)
      watch = Viewing::Catalog.watch_index(profile, clips)
      durations = Edition.where(playable_type: "Clip", playable_id: clips.map(&:id)).joins(:media_file)
        .pluck(:playable_id, "media_files.duration_seconds").to_h
      clips.map do |clip|
        state = watch[clip.id]
        {
          kind: "clip", id: clip.id, title: clip.title, captured_at: clip.captured_at, captured_floating: clip.captured_floating,
          city: clip.city, country: clip.country,
          favorite: clip.favorite, duration_seconds: durations[clip.id]&.to_f, images: ArtworkSerializer.images(images, clip),
          **CatalogSerializer.watch_json(state)
        }
      end
    end

    # "On this day": clips taken on today's date in earlier years.
    sig { params(scope: T.untyped, today: Date).returns(T.untyped) }
    def self.on_this_day(scope, today = Date.current)
      scope.where("EXTRACT(MONTH FROM captured_at) = ? AND EXTRACT(DAY FROM captured_at) = ? AND captured_at < ?",
        today.month, today.day, today.beginning_of_day)
    end
  end
end
