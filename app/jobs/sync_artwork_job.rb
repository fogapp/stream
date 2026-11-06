# typed: strict
# frozen_string_literal: true

# Renders one owner's TMDB artwork (PROPOSAL §5.5), then, for a playable
# still without a picture, a frame from its file.
class SyncArtworkJob < ApplicationJob
  extend T::Sig

  OWNERS = T.let({
    "Movie" => Movie, "Show" => Show, "Season" => Season, "Episode" => Episode, "Person" => Person, "Extra" => Extra,
    "Collection" => Collection, "CollectionPart" => CollectionPart, "Channel" => Channel, "Video" => Video,
    "Clip" => Clip, "HomePerson" => HomePerson
  }.freeze, T::Hash[String, T.class_of(ApplicationRecord)])

  queue_as :artwork
  limits_concurrency to: 1, key: ->(owner_type, owner_id) { "artwork:#{owner_type}:#{owner_id}" }
  retry_on UpstreamHttpClient::RateLimitError, wait: 1.minute, attempts: 5

  sig { params(owner_type: String, owner_id: String).void }
  def perform(owner_type, owner_id)
    owner = OWNERS[owner_type]&.unscoped&.find_by(id: owner_id)
    # An extra has no provider pictures: a frame is its picture.
    return Artworks::FrameGrab.new(owner).call if owner.is_a?(Extra) || owner.is_a?(Clip)
    return Artworks::ImmichFaces.sync(owner) if owner.is_a?(HomePerson)
    # Channels and videos are pictured by what sits beside them, then by
    # YouTube's own pictures, and a video with neither by a frame.
    if owner.is_a?(Channel) || owner.is_a?(Video)
      Artworks::Local.new(owner).call
      Artworks::YoutubeImages.sync(owner)
      Artworks::FrameGrab.new(owner).call if owner.is_a?(Video)
      return
    end
    return unless owner.is_a?(Movie) || owner.is_a?(Show) || owner.is_a?(Season) || owner.is_a?(Episode) || owner.is_a?(Person) ||
      owner.is_a?(Collection) || owner.is_a?(CollectionPart)

    Artworks::Sync.new(owner).call
    Artworks::FrameGrab.new(owner).call if owner.is_a?(Movie) || owner.is_a?(Episode)
  end
end
