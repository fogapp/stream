# typed: strict
# frozen_string_literal: true

# Something you press play on (PROPOSAL §4.2): a movie or an episode, held by
# one or more files through editions ("4K HDR", "Director's Cut").
module Playable
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    has_many :editions, as: :playable, dependent: :delete_all
    has_many :media_files, through: :editions
  end

  # The files that can be played.
  sig { returns(T.untyped) }
  def playable_files = T.unsafe(self).media_files.playable

  # The largest of them, as Play picks among equals.
  sig { returns(T.nilable(MediaFile)) }
  def best_file = playable_files.order(size: :desc).first
end
