# typed: strict
# frozen_string_literal: true

class AlbumClip < ApplicationRecord
  extend T::Sig

  belongs_to :album
  belongs_to :clip
end
