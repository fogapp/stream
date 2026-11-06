# typed: strict
# frozen_string_literal: true

# A TV show (PROPOSAL §4.2), grouped by its folder under the library root
# before any provider is asked, so episodes land together even unmatched.
class Show < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include Matchable

  belongs_to :library
  # Every folder it's filed from; `folder` is the first.
  has_many :folders, -> { order(:folder) }, class_name: "ShowFolder", dependent: :delete_all, inverse_of: :show
  has_one :trailer, as: :owner, dependent: :destroy
  has_many :seasons, -> { order(:season_number) }, dependent: :destroy, inverse_of: :show
  has_many :episodes, -> { order(:season_number, :episode_number) }, dependent: :destroy, inverse_of: :show
  has_many :credits, -> { order(:order) }, as: :creditable, dependent: :delete_all, inverse_of: :creditable
  has_many :extras, as: :owner, dependent: :nullify, inverse_of: :owner
  has_many :collection_items, as: :item, dependent: :delete_all, inverse_of: :item

  has_neighbors :embedding

  validates :title, :folder, presence: true

  # A show is filed from its first folder from the start. A folder already
  # filed (one being split off into a show of its own) keeps its row.
  after_create do
    ShowFolder.unscoped.create_or_find_by!(library_id: library_id, folder: folder) do |row|
      row.household_id = household_id
      row.show_id = id
    end
  end
end
