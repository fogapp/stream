# typed: strict
# frozen_string_literal: true

# A profile's stars for a movie, show or episode (PROPOSAL §7.4), out of 10.
class Rating < ApplicationRecord
  extend T::Sig

  belongs_to :profile
  belongs_to :rateable, polymorphic: true

  validates :value, numericality: { greater_than: 0, less_than_or_equal_to: 10 }

  # A profile's stars for each of these, found in one query, or a new one
  # for each it hasn't rated: what an import reads a page at a time.
  sig { params(profile: Profile, rateables: T::Array[T.any(Movie, Show, Episode)]).returns(T::Hash[[ String, String ], Rating]) }
  def self.index_for(profile, rateables)
    found = rateables.empty? ? {} : where(profile: profile, rateable: rateables.uniq).index_by { |row| [ row.rateable_type.to_s, row.rateable_id.to_s ] }
    rateables.each { |rateable| found[[ rateable.class.polymorphic_name, rateable.id ]] ||= new(profile: profile, rateable: rateable) }
    found
  end
end
