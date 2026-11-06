# typed: strict
# frozen_string_literal: true

# Links a playable to a file that holds it (PROPOSAL §4.2).
class Edition < ApplicationRecord
  extend T::Sig

  belongs_to :media_file

  # Editions whose file plays: probed, not missing or broken.
  scope :readable, -> { joins(:media_file).where(media_files: { state: MediaFile::State::Probed.serialize }) }
  belongs_to :playable, polymorphic: true
end
