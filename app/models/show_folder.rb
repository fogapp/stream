# typed: strict
# frozen_string_literal: true

# One folder a show is filed from (PROPOSAL §4.2). A show usually has one;
# two copies of a show in different folders ("Bluey" and "Bluey (2018)")
# matched to the same TMDB title share one show and keep both rows, so a
# scan of either folder finds it.
class ShowFolder < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :library
  belongs_to :show, inverse_of: :folders

  validates :folder, presence: true
end
