# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The watching profile's playlists (PROPOSAL §7.4): its own, made here
    # or brought from Plex.
    class PlaylistsController < BaseController
      finds :playlist, from: -> { Playlist.all }
      skip_before_action :set_playlist, only: %i[index create]
      before_action :require_own_playlist, except: %i[index create]

      sig { void }
      def index
        Playlist.watch_later_for(current_profile!)
        playlists = Playlist.where(profile: current_profile!).order(Arel.sql("system_kind IS NULL, title")).to_a
        items = Playlist.items_for(playlists)
        images = ArtworkSerializer.index(items.values.flatten.flat_map { |item| [ item, item.try(:show) ].compact }.uniq)
        render json: playlists.map { |playlist| PlaylistSerializer.card(playlist, items.fetch(playlist.id), images) }
      end

      sig { void }
      def show
        items = playlist.items
        images = ArtworkSerializer.index(items.flat_map { |item| [ item, item.try(:show) ].compact }.uniq)
        cards = Viewing::Cards.new(current_profile!).prime(items)
        render json: PlaylistSerializer.card(playlist, items, images).merge(
          pinned_to_home: Array(current_profile!.home_layout["pinned"]).any? { |pin| pin["kind"] == "playlist" && pin["id"] == playlist.id },
          items: items.map { |item| cards.card(item) }
        )
      end

      sig { void }
      def create
        created = Playlist.new(profile: current_profile!, title: params[:title].to_s.strip)
        created.save!

        add(created, params[:item_type], params[:item_id]) if params[:item_id].present?
        render json: { id: created.id, title: created.title }, status: :created
      end

      sig { void }
      def update
        return render_errors("Watch later keeps its name") if playlist.watch_later?
        return render_errors(playlist.errors.full_messages) unless playlist.update(title: params[:title].to_s.strip)

        show
      end

      sig { void }
      def destroy
        return render_errors("Watch later is always there; empty it instead") if playlist.watch_later?

        playlist.destroy!
        head :no_content
      end

      sig { void }
      def add_item
        add(playlist, params.require(:item_type), params.require(:item_id))
        head :no_content
      end

      sig { void }
      def remove_item
        klass = item_class(params.require(:item_type))
        removed = PlaylistItem.where(playlist: playlist, item_type: klass.name, item_id: params.require(:item_id).to_s).delete_all
        Trakt::Outbox.watch_later(current_profile!.id, klass.find_by(id: params[:item_id].to_s), saved: false) if removed.positive? && playlist.watch_later?
        head :no_content
      end

      # { ids: [item ids in the new order] }
      sig { void }
      def reorder
        PlaylistItem.reposition!(playlist.playlist_items, Array(params[:ids]).map(&:to_s))
        head :no_content
      end

      private

      # Another profile's playlist is as good as not there.
      sig { void }
      def require_own_playlist
        raise ActiveRecord::RecordNotFound unless playlist.profile_id == current_profile!.id
      end

      sig { params(target: Playlist, type: T.untyped, id: T.untyped).void }
      def add(target, type, id)
        target.add!(T.cast(Viewing::Playables.find!(type, id, only: %w[movie episode video]), T.any(Movie, Episode, Video)))
      end

      sig { params(type: String).returns(T.any(T.class_of(Movie), T.class_of(Episode), T.class_of(Video))) }
      def item_class(type)
        case type
        when "movie" then Movie
        when "episode" then Episode
        when "video" then Video
        else raise ActiveRecord::RecordNotFound
        end
      end
    end
  end
end
