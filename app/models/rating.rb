# typed: strict
# frozen_string_literal: true

# A profile's stars for a movie, show or episode (PROPOSAL §7.4), out of 10.
class Rating < ApplicationRecord
  extend T::Sig

  belongs_to :profile
  belongs_to :rateable, polymorphic: true

  validates :value, numericality: { greater_than: 0, less_than_or_equal_to: 10 }
end
