# typed: strict
# frozen_string_literal: true

# A playlist as the Playlists page and its own page show it (PROPOSAL §7.1).
module PlaylistSerializer
  extend T::Sig

  sig do
    params(playlist: Playlist, items: T::Array[T.any(Movie, Episode, Video)], images: ArtworkSerializer::Index)
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.card(playlist, items, images)
    first = items.first
    picture = case first
    when Movie, Video then ArtworkSerializer.images(images, first).values_at("backdrop", "thumb").compact.first
    when Episode
      ArtworkSerializer.images(images, first).values_at("still", "thumb").compact.first ||
        (first.show && ArtworkSerializer.images(images, T.must(first.show))["backdrop"])
    end
    {
      id: playlist.id, title: playlist.title, item_count: items.size, from_plex: playlist.plex_key.present?,
      watch_later: playlist.watch_later?,
      image: picture, first: first && { kind: first.class.name.to_s.downcase, id: first.id }
    }
  end
end
