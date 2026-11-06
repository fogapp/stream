# typed: strict
# frozen_string_literal: true

# What one library root looked like the last time Libraries::ChangeDetector
# listed it: { relative path => mtime (epoch seconds) }.
class FolderListing < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :library

  validates :root, presence: true
end
