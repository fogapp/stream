# typed: strict
# frozen_string_literal: true

# A film (PROPOSAL §4.2): the cinematic shape's playable.
class Movie < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include Matchable
  include Playable

  belongs_to :library
  has_one :trailer, as: :owner, dependent: :destroy
  has_many :credits, -> { order(:order) }, as: :creditable, dependent: :delete_all, inverse_of: :creditable
  has_many :extras, as: :owner, dependent: :nullify, inverse_of: :owner
  has_many :collection_items, as: :item, dependent: :delete_all, inverse_of: :item

  has_neighbors :embedding
  has_many :playlist_items, as: :item, dependent: :delete_all, inverse_of: :item

  validates :title, presence: true

  # The title as Catalog::FileMatcher compares titles, so finding a film by
  # name is a lookup (index on library_id, normalized_title).
  before_save { self.normalized_title = Media::NameParser.normalize(title.to_s) if title_changed? || normalized_title.nil? }
end
