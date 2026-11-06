# typed: strict
# frozen_string_literal: true

module WebauthnCredentialSerializer
  extend T::Sig

  sig { params(credential: WebauthnCredential).returns(T::Hash[Symbol, T.untyped]) }
  def self.credential_json(credential)
    {
      id: credential.id, nickname: credential.nickname,
      created_at: credential.created_at, last_used_at: credential.last_used_at
    }
  end
end
