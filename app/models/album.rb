# typed: strict
# frozen_string_literal: true

# A set of home videos (PROPOSAL §5.4): an Immich album, brought over.
class Album < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  has_many :album_clips, dependent: :delete_all
  has_many :clips, through: :album_clips

  validates :title, presence: true
end
