# typed: strict
# frozen_string_literal: true

# "Hide from this profile": a movie, show or YouTube channel that appears
# nowhere on the profile (Viewing::Access) — not in rows, search, the Grid or
# its own page — whatever its rating or tags say.
class ProfileExclusion < ApplicationRecord
  extend T::Sig

  EXCLUDABLE = T.let(%w[Movie Show Channel].freeze, T::Array[String])

  belongs_to :profile
  belongs_to :excludable, polymorphic: true

  validates :excludable_type, inclusion: { in: EXCLUDABLE }
end
