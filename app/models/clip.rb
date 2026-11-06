# typed: strict
# frozen_string_literal: true

# A home video (PROPOSAL §4.2): the home-video shape's playable, placed in
# time by when it was taken.
class Clip < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include Playable
  include LockedFields

  class CapturedSource < T::Enum
    include ApplicationEnum
    enums do
      Immich = new("immich")
      Metadata = new("metadata")
      Filename = new("filename")
      FileDate = new("file_date")
    end
  end

  belongs_to :library
  has_many :album_clips, dependent: :delete_all
  has_many :albums, through: :album_clips
  has_many :clip_people, dependent: :delete_all
  has_many :home_people, through: :clip_people
  has_many :playlist_items, as: :item, dependent: :delete_all, inverse_of: :item

  attribute :captured_source, CapturedSource

  validates :title, presence: true
  before_validation { self.sort_title = title.to_s.downcase }
end
