# typed: strict
# frozen_string_literal: true

# Someone Immich has recognised and been told the name of (PROPOSAL §5.4).
class HomePerson < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  has_many :clip_people, dependent: :delete_all
  has_many :clips, through: :clip_people

  validates :name, presence: true
end
