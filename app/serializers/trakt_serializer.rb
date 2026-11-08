# typed: strict
# frozen_string_literal: true

# Trakt's settings and a profile's link (PROPOSAL §7.4). Never a secret,
# never a token.
module TraktSerializer
  extend T::Sig

  sig { params(setting: T.nilable(TraktSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.setting_json(setting)
    return { configured: false } if setting.nil?

    {
      configured: true, client_id: setting.client_id, **ConnectionTestSerializer.tested(setting)
    }
  end

  # What Settings › Viewing shows the watching profile.
  sig { params(available: T::Boolean, account: T.nilable(TraktAccount)).returns(T::Hash[Symbol, T.untyped]) }
  def self.account_json(available:, account:)
    { available: available, account: account && link_json(account) }
  end

  sig { params(account: TraktAccount).returns(T::Hash[Symbol, T.untyped]) }
  def self.link_json(account)
    pending = account.state_enum == TraktAccount::State::Pending
    {
      state: account.state_enum, username: account.username, linked_at: account.linked_at,
      last_synced_at: account.last_synced_at, last_error: account.last_error, last_error_at: account.last_error_at,
      user_code: pending ? account.user_code : nil, verification_url: pending ? account.verification_url : nil,
      code_expires_at: pending ? account.device_expires_at : nil, poll_interval: pending ? account.poll_interval : nil
    }
  end
end
