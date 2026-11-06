# typed: strict
# frozen_string_literal: true

module Auth
  # Sign in with fog — or with any OpenID provider OIDC_ISSUER names
  # (fog:docs/signin-proposal.md §15). The flow is the shared
  # FogClient::Signin::Rails; Stream supplies what an identity means for its
  # accounts (SigninAdapter), visitors from paired households included.
  # Outside the bearer-token stack: these are the doors to it. The kit limits
  # the link step like password sign-in (Api::V1::SessionsController) itself.
  class OidcController < ActionController::API
    extend T::Sig
    include FogClient::Signin::Rails

    private

    sig { returns(SigninAdapter) }
    def signin_adapter = SigninAdapter.new
  end
end
