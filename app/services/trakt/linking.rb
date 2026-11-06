# typed: strict
# frozen_string_literal: true

module Trakt
  # Linking a profile to its Trakt account with a device code (PROPOSAL
  # §7.4): Stream asks Trakt for a code, the person enters it at
  # trakt.tv/activate, and Stream polls until Trakt says yes. Polling is
  # driven by the screen showing the code, never faster than Trakt asked.
  module Linking
    extend T::Sig

    class NotSetUp < StandardError; end

    sig { params(profile: Profile).returns(TraktAccount) }
    def self.start(profile)
      setting = TraktSetting.find_by(household_id: profile.household_id)
      raise NotSetUp, "Trakt isn't set up yet. An admin adds it in Settings › Integrations." if setting.nil?

      code = Client.new(setting).device_code
      account = TraktAccount.find_or_initialize_by(profile: profile)
      account.assign_attributes(state: TraktAccount::State::Pending.serialize, device_code: code.fetch("device_code"),
        user_code: code.fetch("user_code"), verification_url: code.fetch("verification_url"),
        poll_interval: code.fetch("interval", 5).to_i, device_expires_at: code.fetch("expires_in").to_i.seconds.from_now,
        polled_at: nil, access_token: nil, refresh_token: nil, expires_at: nil, last_error: nil, last_error_at: nil)
      account.save!
      account
    end

    # One look at whether the code was entered. Returns the account as it
    # now stands.
    sig { params(account: TraktAccount).returns(TraktAccount) }
    def self.poll(account)
      return account unless account.state_enum == TraktAccount::State::Pending
      return account if expired?(account) || too_soon?(account)

      setting = TraktSetting.find_by!(household_id: account.household_id)
      client = Client.new(setting)
      result = client.device_token(account.device_code.to_s)
      account.update!(polled_at: Time.current)
      status = result.status
      case status
      when Client::DeviceStatus::Linked then link!(account, client, result.tokens)
      when Client::DeviceStatus::Pending then nil
      when Client::DeviceStatus::SlowDown then account.update!(poll_interval: account.poll_interval.to_i + 5)
      when Client::DeviceStatus::Expired, Client::DeviceStatus::Invalid then account.update!(device_expires_at: Time.current)
      when Client::DeviceStatus::Denied
        account.update!(device_expires_at: Time.current, last_error: "The code was declined on Trakt.", last_error_at: Time.current)
      else T.absurd(status)
      end
      account
    end

    sig { params(account: TraktAccount).returns(T::Boolean) }
    def self.expired?(account)
      expires = account.device_expires_at
      expires.nil? || expires <= Time.current
    end

    sig { params(account: TraktAccount).returns(T::Boolean) }
    def self.too_soon?(account)
      polled = account.polled_at
      !polled.nil? && polled > account.poll_interval.to_i.seconds.ago
    end

    # Unlinked here, and the token revoked at Trakt when it will listen.
    sig { params(account: TraktAccount).void }
    def self.unlink(account)
      setting = TraktSetting.find_by(household_id: account.household_id)
      token = account.access_token
      begin
        Client.new(setting).revoke(token) if setting && token.present?
      rescue UpstreamHttpClient::Error
        # Revoking is a courtesy; the link is gone from Stream either way.
        nil
      end
      account.destroy!
    end

    sig { params(account: TraktAccount, client: Client, tokens: T::Hash[String, T.untyped]).void }
    def self.link!(account, client, tokens)
      Api.store_tokens(account, tokens)
      settings = client.get("/users/settings", token: account.access_token)
      user = settings.is_a?(Hash) ? settings["user"] : nil
      account.update!(state: TraktAccount::State::Linked.serialize, username: user.is_a?(Hash) ? user["username"] : nil,
        linked_at: Time.current, device_code: nil, user_code: nil, verification_url: nil, device_expires_at: nil,
        last_error: nil, last_error_at: nil)
      Activity.record(source: "trakt", event: "trakt.linked", subject: account, household_id: account.household_id,
        summary: "#{account.profile&.name} linked Trakt#{account.username ? " as #{account.username}" : ''}")
      # The first sync: both sides' history, stars and watchlist merged.
      TraktPullJob.perform_later(account.id)
    end
    private_class_method :link!
  end
end
