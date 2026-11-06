# typed: strict
# frozen_string_literal: true

# One row per signed-in client (hub:app/models/api_session.rb). Opaque
# tokens; revocation is row deletion (logout / settings). A session from a
# password, passkey or pairing never expires; one from fog sign-in lives no
# longer than FOG_TTL, and fog's back-channel logout ends it by its sid.
class ApiSession < ApplicationRecord
  extend T::Sig

  # Throttle last_used_at writes so hot paths don't UPDATE per request.
  USE_STAMP_INTERVAL = T.let(1.hour, ActiveSupport::Duration)
  # A session from fog sign-in lives no longer than the fog session behind
  # it; back-channel logout usually ends it sooner, and this is what heals a
  # logout that never arrived (fog:docs/signin-proposal.md §11).
  FOG_TTL = T.let(30.days, ActiveSupport::Duration)
  # A visitor's (fog:docs/signin-proposal.md §10.4) lives no longer than
  # fog's visitor session behind it.
  VISITOR_TTL = T.let(12.hours, ActiveSupport::Duration)
  # The callback hands the console a code, not the token: the code rides in
  # a URL fragment for one redirect and is good once, for a minute.
  HANDOFF_TTL = T.let(1.minute, ActiveSupport::Duration)

  belongs_to :user

  validates :token, presence: true, uniqueness: true

  sig do
    params(user: User, device: T.nilable(String), oidc_sid: T.nilable(String),
      expires_at: T.nilable(ActiveSupport::TimeWithZone)).returns(ApiSession)
  end
  def self.generate!(user:, device: nil, oidc_sid: nil, expires_at: nil)
    create!(user: user, token: SecureRandom.hex(32), device: device, last_used_at: Time.current,
      oidc_sid: oidc_sid, expires_at: expires_at)
  end

  # The live session for a bearer token: an expired one reads as none, and
  # is removed on the way.
  sig { params(token: String).returns(T.nilable(ApiSession)) }
  def self.live(token)
    session = find_by(token: token)
    return session unless session&.expired?

    session.destroy
    nil
  end

  sig { returns(T::Boolean) }
  def expired?
    at = expires_at
    !at.nil? && at <= Time.current
  end

  # A one-time code the console exchanges for this session's token. Only its
  # digest is kept.
  sig { params(ttl: ActiveSupport::Duration).returns(String) }
  def issue_handoff!(ttl: HANDOFF_TTL)
    code = SecureRandom.urlsafe_base64(32)
    update!(handoff_digest: Digest::SHA256.hexdigest(code), handoff_expires_at: ttl.from_now)
    code
  end

  # The session a handoff code names — once: two racing redemptions cannot
  # both win, because the database spends the code.
  sig { params(code: String).returns(T.nilable(ApiSession)) }
  def self.redeem_handoff(code)
    return nil if code.blank?

    digest = Digest::SHA256.hexdigest(code)
    session = find_by(handoff_digest: digest)
    return nil if session.nil?

    spent = where(id: session.id, handoff_digest: digest).where("handoff_expires_at > ?", Time.current)
      .update_all(handoff_digest: nil, handoff_expires_at: nil) # rubocop:disable Rails/SkipsModelValidations
    spent == 1 && !session.expired? ? session : nil
  end

  sig { void }
  def record_use!
    stamp = last_used_at
    return if stamp.present? && stamp > USE_STAMP_INTERVAL.ago

    update_column(:last_used_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
