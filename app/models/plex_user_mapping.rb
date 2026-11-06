# typed: strict
# frozen_string_literal: true

# One Plex home user, and the Stream profile their history goes to (nil:
# not imported).
class PlexUserMapping < ApplicationRecord
  extend T::Sig

  belongs_to :plex_connection
  belongs_to :profile, optional: true

  validates :plex_user_id, :plex_name, presence: true
end
