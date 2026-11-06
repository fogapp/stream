# typed: strict
# frozen_string_literal: true

# A TV asking to be signed in (PROPOSAL §7.4). Not household-scoped until
# someone in a household approves it.
class DevicePairing < ApplicationRecord
  extend T::Sig

  class State < T::Enum
    include ApplicationEnum
    enums do
      Pending = new("pending")
      Approved = new("approved")
      # The TV has its session; the row is spent.
      Collected = new("collected")
    end
  end

  # No 0/O or 1/I: read off a TV across the room.
  ALPHABET = T.let("ABCDEFGHJKLMNPQRSTUVWXYZ23456789".chars.freeze, T::Array[String])
  LIFETIME = T.let(10.minutes, ActiveSupport::Duration)

  belongs_to :user, optional: true
  encrypts :session_token

  attribute :state, State

  sig { params(device_label: String).returns(DevicePairing) }
  def self.start!(device_label)
    create!(code: Array.new(8) { ALPHABET.sample(random: SecureRandom) }.join, poll_token: SecureRandom.hex(32),
      device_label: device_label.first(80), expires_at: LIFETIME.from_now)
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  # "abcd efgh", "ABCD-EFGH" → "ABCDEFGH".
  sig { params(text: String).returns(String) }
  def self.normalize(text) = text.upcase.gsub(/[^A-Z0-9]/, "")

  sig { returns(T::Boolean) }
  def expired? = expires_at < Time.current

  sig { returns(String) }
  def display_code = "#{code[0, 4]}-#{code[4, 4]}"
end
