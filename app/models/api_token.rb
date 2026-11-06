# typed: strict
# frozen_string_literal: true

# A long-lived, machine-facing credential (hub:app/models/api_token.rb) —
# the sibling of ApiSession, which is minted by an interactive login and
# dies with it. Integrations and scripts (a yt-dlp post-processor, a
# home-automation hub) hold these. Only the SHA-256 digest is stored; the
# plaintext exists once, in the create response.
#
# `scope` narrows what a token may do: `full` is its owner's access; `read`
# may look at everything and change nothing (ApplicationController refuses
# it anything but a GET) — the shape to hand a wall display or another app
# that only shows what is playing.
class ApiToken < ApplicationRecord
  extend T::Sig

  class Scope < T::Enum
    include ApplicationEnum
    enums do
      Full = new("full")
      Read = new("read")
    end
  end

  PREFIX = "stream_"
  TOKEN_BYTES = 24
  DISPLAY_PREFIX_LENGTH = T.let(PREFIX.length + 6, Integer)
  MAX_NAME_LENGTH = 80
  MAX_EXPIRES_IN_DAYS = 3650

  class Generated < T::Struct
    const :api_token, ApiToken
    const :token, String
  end

  belongs_to :user

  attribute :scope, Scope

  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validates :token_digest, presence: true, uniqueness: true
  validates :prefix, presence: true

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  sig { params(user: User, name: String, expires_at: T.nilable(Time), scope: Scope).returns(Generated) }
  def self.generate(user:, name:, expires_at: nil, scope: Scope::Full)
    token = "#{PREFIX}#{SecureRandom.hex(TOKEN_BYTES)}"
    record = new(user: user, name: name, expires_at: expires_at, scope: scope.serialize,
      token_digest: digest(token), prefix: token.first(DISPLAY_PREFIX_LENGTH))
    record.save
    Generated.new(api_token: record, token: token)
  end

  sig { params(token: String).returns(String) }
  def self.digest(token) = Digest::SHA256.hexdigest(token)

  # nil for anything that isn't a live API token — including strings that
  # aren't API tokens at all, which fall through to ApiSession unqueried.
  sig { params(token: T.nilable(String)).returns(T.nilable(ApiToken)) }
  def self.authenticate(token)
    return nil unless token&.start_with?(PREFIX)

    active.find_by(token_digest: digest(token))
  end

  sig { returns(T::Boolean) }
  def expired?
    expiry = expires_at
    expiry.present? && expiry.past?
  end

  sig { returns(T::Boolean) }
  def read_only? = scope_enum == Scope::Read

  sig { void }
  def record_use!
    return if (last = last_used_at) && last > 1.hour.ago

    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
