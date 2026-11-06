# typed: strict
# frozen_string_literal: true

# Whether Stream signs people in through an OpenID provider, and whether it
# does so exclusively (fog:docs/signin-proposal.md §15, §23.2).
#
# Fog-only is earned, not configured: Stream turns its own sign-in off only
# after proving it runs on fog — the fog that recognises Stream's own
# FOG_API_TOKEN signs, with the key that signs Stream's ID tokens, the issuer
# and client Stream is configured with. Once proven it stays on: a later
# failure to reach fog never re-opens local passwords, or blocking fogd
# would be a way to switch them back. It ends only when the FOG_* variables
# are gone (Stream was taken off fog) — and the console's recovery link
# (bin/rails stream:recovery_link) is always there for a broken fog.
module FogSignin
  extend T::Sig

  sig { returns(T::Boolean) }
  def self.enabled? = FogClient::Signin.enabled?

  sig { returns(T::Boolean) }
  def self.fog_only?
    enabled? && ENV["FOG_API_URL"].present? && AppSetting.cached.fog_attested_at.present?
  end

  # Prove it now if it has not been proven yet. Cheap once proven; called
  # where the console asks how to sign in.
  sig { void }
  def self.attest_if_needed
    return if !enabled? || ENV["FOG_API_URL"].blank? || AppSetting.cached.fog_attested_at.present?

    config = FogClient::Signin.config
    return if config.nil?
    return unless FogClient::Signin::Proof.check(FogClient::Signin::Rails.provider_for(config))

    AppSetting.current.update!(fog_attested_at: Time.current)
    Activity.record(source: "auth", event: "fog_only",
      summary: "Stream proved it runs on fog: from now on everyone signs in with fog")
  end
end
