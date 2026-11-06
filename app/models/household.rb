# typed: strict
# frozen_string_literal: true

class Household < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :invite_codes, dependent: :destroy
  has_one :tmdb_setting, dependent: :destroy

  validates :name, presence: true
end
