# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Home videos (PROPOSAL §5.4): a library's clips newest first, a page at
    # a time, filtered by album, person or favourites; and one clip's page.
    class ClipsController < BaseController
      finds :clip, from: -> { Viewing::Access.clips(Clip.all) }
      skip_before_action :set_clip, only: %i[index filters places]

      PER = 120

      sig { void }
      def index
        scope = HomeVideos::Catalog.watchable
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        scope = scope.where(id: AlbumClip.where(album_id: params[:album_id].to_s).select(:clip_id)) if params[:album_id].present?
        scope = scope.where(id: ClipPerson.where(home_person_id: params[:person_id].to_s).select(:clip_id)) if params[:person_id].present?
        scope = scope.where(favorite: true) if bool_param(:favorites)
        years = scope.group(Arel.sql("EXTRACT(YEAR FROM captured_at)::int")).count.sort.reverse.map { |year, count| { year: year, count: count } }
        before = parse_param_time(:before)
        page = scope.then { |relation| before ? relation.where(captured_at: ...before) : relation }
          .order(captured_at: :desc).limit(PER).to_a
        render json: { years: years, clips: HomeVideos::Catalog.cards(current_profile!, page), more: page.size == PER }
      end

      # Where a library's clips were taken, for the map (PROPOSAL §5.4):
      # places about a kilometre across, each with how many and a few to
      # show. Only clips with coordinates (Immich's) are on it.
      sig { void }
      def places
        clips = HomeVideos::Catalog.watchable.where.not(latitude: nil).where.not(longitude: nil)
        clips = clips.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        groups = clips.order(captured_at: :desc).to_a.group_by { |clip| [ clip.latitude.to_f.round(2), clip.longitude.to_f.round(2) ] }
        shown = groups.values.flat_map { |list| list.first(6) }
        cards = HomeVideos::Catalog.cards(current_profile!, shown).index_by { |card| card[:id] }
        render json: groups.map { |(latitude, longitude), list|
          first = list.first
          { latitude: latitude, longitude: longitude, count: list.size, city: first.city, country: first.country,
            clips: list.first(6).filter_map { |clip| cards[clip.id] } }
        }.sort_by { |place| -place[:count] }.first(500)
      end

      # The albums and people a library's clips can be narrowed to.
      sig { void }
      def filters
        clips = HomeVideos::Catalog.watchable
        clips = clips.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        albums = T.cast(Album.joins(:album_clips).where(album_clips: { clip_id: clips.select(:id) }).group("albums.id", "albums.title")
          .order("albums.title").count, T::Hash[[ String, String ], Integer])
        people = HomePerson.joins(:clip_people).where(clip_people: { clip_id: clips.select(:id) }).group(:id).count
        rows = HomePerson.where(id: people.keys).order(:name).to_a
        images = ArtworkSerializer.index(rows)
        render json: {
          albums: albums.map { |(id, title), count| { id: id, title: title, count: count } },
          people: rows.map { |person| { id: person.id, name: person.name, count: people[person.id], image: ArtworkSerializer.images(images, person)["profile"] } },
          favorites: clips.where(favorite: true).count
        }
      end

      sig { void }
      def show
        card = HomeVideos::Catalog.cards(current_profile!, [ clip ]).first || {}
        day = clip.captured_at.to_date
        same_day = HomeVideos::Catalog.watchable(Clip.where(library_id: clip.library_id, captured_at: day.all_day))
          .where.not(id: clip.id).order(:captured_at).limit(24).to_a
        state = WatchState.find_by(profile: current_profile!, playable: clip)
        render json: card.merge(
          description: clip.description, latitude: clip.latitude, longitude: clip.longitude,
          captured_source: clip.captured_source_enum.serialize, library: { id: clip.library_id, name: clip.library&.name },
          albums: clip.albums.order(:title).map { |album| { id: album.id, title: album.title } },
          people: clip.home_people.order(:name).map { |person| { id: person.id, name: person.name } },
          resume_at: state&.resume_seconds,
          same_day: HomeVideos::Catalog.cards(current_profile!, same_day)
        )
      end
    end
  end
end
