# typed: strict
# frozen_string_literal: true

# Proof that this browser chose a profile (PROPOSAL §7.4) — and passed its
# PIN, if it has one. Signed by the server, so a client can't just name a
# profile; a PIN change makes every earlier token for it stale.
module ProfileTokens
  extend T::Sig

  LIFETIME = T.let(180.days, ActiveSupport::Duration)

  sig { params(profile: Profile).returns(String) }
  def self.issue(profile)
    verifier.generate({ "p" => profile.id, "h" => profile.household_id, "v" => stamp(profile) },
      expires_in: LIFETIME, purpose: :profile)
  end

  sig { params(token: String, household_id: String).returns(T.nilable(Profile)) }
  def self.verify(token, household_id)
    data = verifier.verified(token, purpose: :profile)
    return nil unless data.is_a?(Hash) && data["h"] == household_id

    profile = Profile.unscoped.find_by(id: data["p"], household_id: household_id)
    profile if profile && stamp(profile) == data["v"]
  end

  # When the PIN last changed, to the microsecond.
  sig { params(profile: Profile).returns(Integer) }
  def self.stamp(profile) = (profile.pin_changed_at.to_f * 1_000_000).round
  private_class_method :stamp

  sig { returns(ActiveSupport::MessageVerifier) }
  def self.verifier = Rails.application.message_verifier("stream_profile")
  private_class_method :verifier
end
