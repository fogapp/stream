# typed: strict
# frozen_string_literal: true

# An episode (PROPOSAL §4.2). Episodes exist from provider metadata even
# with no file (so the season page can show what's missing) and from files
# even without a provider (so an unmatched show still plays).
class Episode < ApplicationRecord
  extend T::Sig
  include Playable

  belongs_to :show, inverse_of: :episodes
  belongs_to :season, inverse_of: :episodes
  has_many :playlist_items, as: :item, dependent: :delete_all, inverse_of: :item

  sig { returns(String) }
  def code
    format("S%<season>02dE%<episode>02d", season: season_number, episode: episode_number.to_i)
  end
end
