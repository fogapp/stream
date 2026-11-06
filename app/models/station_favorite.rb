# typed: strict
# frozen_string_literal: true

# A channel a profile keeps near the top of its guide (PROPOSAL §7.7).
class StationFavorite < ApplicationRecord
  belongs_to :profile
  belongs_to :station
end
