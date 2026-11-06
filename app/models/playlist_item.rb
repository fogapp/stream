# typed: strict
# frozen_string_literal: true

class PlaylistItem < ApplicationRecord
  extend T::Sig

  belongs_to :playlist
  belongs_to :item, polymorphic: true
end
