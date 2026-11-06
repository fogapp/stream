# typed: strict
# frozen_string_literal: true

# "For this profile" (PROPOSAL §7.4): what a curated profile sees, and
# what a rating-limited one may see regardless of its rating.
class ProfileTag < ApplicationRecord
  extend T::Sig

  TAGGABLE = T.let(%w[Movie Show Channel Album].freeze, T::Array[String])

  belongs_to :profile
  belongs_to :taggable, polymorphic: true

  validates :taggable_type, inclusion: { in: TAGGABLE }
end
