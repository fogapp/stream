# typed: strict
# frozen_string_literal: true

# One profile's Trakt account (PROPOSAL §7.4): what it watches is scrobbled
# there, its history, ratings and watchlist kept in step both ways. Linked
# with a device code, so it works from a TV as well as a browser; tokens are
# stored encrypted and never sent back.
class TraktAccount < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class State < T::Enum
    include ApplicationEnum
    enums do
      # Waiting for the code to be entered at trakt.tv/activate.
      Pending = new("pending")
      Linked = new("linked")
      # Trakt stopped accepting the tokens (revoked, or the app changed):
      # nothing syncs until it's linked again.
      NeedsRelink = new("needs_relink")
    end
  end

  attribute :state, State

  belongs_to :profile
  has_many :trakt_changes, dependent: :delete_all

  encrypts :device_code, :access_token, :refresh_token

  validate :adult_profile

  scope :linked, -> { where(state: State::Linked.serialize) }

  # A linked profile's account, or nil: the one question every writer asks
  # before it records anything for Trakt.
  sig { params(profile_id: T.nilable(String)).returns(T.nilable(TraktAccount)) }
  def self.linked_for(profile_id)
    return nil if profile_id.nil?

    unscoped.linked.find_by(profile_id: profile_id)
  end

  sig { params(message: String).void }
  def record_error!(message)
    update!(last_error: message.truncate(250), last_error_at: Time.current)
  end

  private

  sig { void }
  def adult_profile
    errors.add(:profile, "is a kid profile; kid profiles don't link Trakt") if profile&.kid?
  end
end
