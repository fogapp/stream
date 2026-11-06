# typed: strict
# frozen_string_literal: true

# One film of a TMDB collection as TMDB lists it (PROPOSAL §4.2), whether a
# library has it or not: the collection's page fades the ones it hasn't.
class CollectionPart < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :collection

  validates :title, presence: true
  validates :tmdb_id, presence: true

  sig { returns(T.nilable(Integer)) }
  def year = release_date&.year
end
