# typed: strict
# frozen_string_literal: true

class Season < ApplicationRecord
  extend T::Sig

  belongs_to :show, inverse_of: :seasons
  has_many :episodes, -> { order(:episode_number) }, dependent: :destroy, inverse_of: :season
  has_many :extras, as: :owner, dependent: :nullify, inverse_of: :owner

  validates :season_number, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  sig { returns(String) }
  def display_title
    title.presence || (season_number.zero? ? "Specials" : "Season #{season_number}")
  end
end
