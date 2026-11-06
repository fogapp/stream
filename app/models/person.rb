# typed: strict
# frozen_string_literal: true

# Someone in front of or behind the camera, as TMDB knows them. Shared across
# households: a person's public filmography is nobody's private data.
class Person < ApplicationRecord
  extend T::Sig

  has_many :credits, dependent: :delete_all

  validates :name, presence: true
end
