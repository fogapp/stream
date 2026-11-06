# typed: strict
# frozen_string_literal: true

# A channel a profile never wants in its guide (PROPOSAL §7.7): one person's
# horror channel needn't be everyone's.
class StationHide < ApplicationRecord
  belongs_to :profile
  belongs_to :station
end
