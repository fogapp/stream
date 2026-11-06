# typed: strict
# frozen_string_literal: true

# The household's Plex server, for migrating away from it (PROPOSAL §7.4).
# Read-only: nothing Stream does changes anything in Plex.
class PlexConnection < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested

  has_many :plex_user_mappings, dependent: :delete_all

  encrypts :token

  normalizes :server_url, with: ->(url) { url.to_s.strip.chomp("/") }

  validates :server_url, presence: true, format: { with: %r{\Ahttps?://[^\s/]+(:\d+)?\z}, message: "should look like http://192.168.1.12:32400" }
  validates :token, presence: true
end
