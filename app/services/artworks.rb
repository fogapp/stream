# typed: strict
# frozen_string_literal: true

# Where artwork work gets queued from, so the metadata code says "these
# changed" and this decides what that means.
module Artworks
  extend T::Sig

  # People beyond this in a cast list are rarely scrolled to; their faces
  # can wait until someone opens their page.
  CAST_FACES = 12

  sig { params(title: T.any(Movie, Show)).void }
  def self.enqueue_for(title)
    owners = T.let([ title ], T::Array[ApplicationRecord])
    if title.is_a?(Show)
      owners.concat(title.seasons.where.not(poster_path: nil).to_a)
      owners.concat(title.episodes.to_a)
    end
    people = Person.joins(:credits).where(credits: { creditable: title, role: Credit::Role::Cast.serialize })
      .where.not(profile_path: nil).order("credits.order").limit(CAST_FACES)
    owners.concat(people.to_a)
    ActiveJob.perform_all_later(owners.map { |owner| SyncArtworkJob.new(owner.class.name, owner.id) })
  end

  sig { params(playable: T.any(Movie, Episode)).void }
  def self.enqueue_playable(playable)
    SyncArtworkJob.perform_later(playable.class.name.to_s, playable.id)
  end
end
