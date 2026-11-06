# typed: strict
# frozen_string_literal: true

# One video on a channel (PROPOSAL §4.2): the channel shape's playable.
class Video < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include LockedFields
  include SortTitled
  include Playable

  class Source < T::Enum
    include ApplicationEnum
    enums do
      InfoJson = new("info_json")
      Nfo = new("nfo")
      Tags = new("tags")
      Folder = new("folder")
      # Asked of YouTube once the video was identified (Youtube::Hydrator):
      # as good as an info.json, for a file that came without one.
      Youtube = new("youtube")
    end
  end

  # Which YouTube video this is (Youtube::Identifier). A video that arrived
  # with its id (an info.json, an [id] in its name) is identified from the
  # start; one put in a folder by hand is looked up by title and length.
  class Identity < T::Enum
    include ApplicationEnum
    enums do
      Unchecked = new("unchecked")
      Identified = new("identified")
      # Close candidates, none sure enough: a person picks.
      NeedsReview = new("needs_review")
      # Nothing on the channel came close (members-only, deleted, renamed).
      NotFound = new("not_found")
      # A person said so: stop asking.
      NotOnYoutube = new("not_on_youtube")
    end
  end

  belongs_to :library
  belongs_to :channel
  has_many :playlist_items, as: :item, dependent: :delete_all, inverse_of: :item
  has_many :sponsor_segments, -> { order(:start_seconds) }, dependent: :delete_all, inverse_of: :video

  has_neighbors :embedding

  attribute :source, Source
  attribute :identity, Identity

  # Still waiting for someone to say which video it is.
  UNIDENTIFIED = T.let([ Identity::Unchecked, Identity::NeedsReview, Identity::NotFound ].freeze, T::Array[Identity])

  validates :title, presence: true
end
