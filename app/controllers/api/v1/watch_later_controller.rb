# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Watch later (PROPOSAL §5.4): one press to save something for the
    # watching profile, in the playlist every profile has.
    class WatchLaterController < BaseController
      sig { void }
      def show
        playlist = Playlist.watch_later_for(current_profile!)
        render json: { id: playlist.id, items: playlist.playlist_items.pluck(:item_type, :item_id).map { |type, id| "#{type.downcase}:#{id}" } }
      end

      sig { void }
      def create
        # Found (or refused) before the list is made: a refusal writes nothing.
        item = find_item
        playlist = Playlist.watch_later_for(current_profile!)
        playlist.add!(item)
        render json: { saved: true, playlist_id: playlist.id }
      end

      sig { void }
      def destroy
        item = find_item
        playlist = Playlist.watch_later_for(current_profile!)
        removed = PlaylistItem.where(playlist: playlist, item: item).delete_all
        Trakt::Outbox.watch_later(current_profile!.id, item, saved: false) if removed.positive?
        render json: { saved: false, playlist_id: playlist.id }
      end

      private

      sig { returns(T.any(Movie, Episode, Video)) }
      def find_item
        T.cast(Viewing::Playables.find!(params.require(:item_type), params.require(:item_id), only: %w[movie episode video]),
          T.any(Movie, Episode, Video))
      end
    end
  end
end
