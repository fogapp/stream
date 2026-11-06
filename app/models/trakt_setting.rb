# typed: strict
# frozen_string_literal: true

# The household's Trakt API app (PROPOSAL §7.4), registered once at
# trakt.tv/oauth/applications and entered in Settings › Integrations. The
# secret is stored encrypted and never sent back; each adult profile then
# links its own Trakt account through it.
class TraktSetting < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested

  encrypts :client_secret

  normalizes :client_id, :client_secret, with: ->(value) { value.to_s.strip }

  validates :client_id, :client_secret, presence: true
end
