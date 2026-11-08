# typed: strict
# frozen_string_literal: true

module Trakt
  # Trakt as one linked profile: every call with a fresh token. Since March
  # 2025 a Trakt access token lasts a day, and each refresh hands back a new
  # refresh token and retires the old one, so refreshing happens under the
  # account's row lock: two jobs refreshing at once would leave one holding a
  # token Trakt no longer knows.
  class Api
    extend T::Sig

    # Trakt stopped accepting this profile's tokens: nothing more is sent
    # until it's linked again.
    class Unlinked < StandardError; end

    # Refreshed this long before it runs out.
    REFRESH_AHEAD = T.let(1.hour, ActiveSupport::Duration)
    # Trakt allows a person one write a second.
    WRITE_SPACING = 1.0

    sig { params(account: TraktAccount).returns(Api) }
    def self.for(account)
      setting = TraktSetting.unscoped.find_by(household_id: account.household_id)
      raise Unlinked, "Trakt isn't set up in Settings › Integrations" if setting.nil?

      new(account, Client.new(setting))
    end

    sig { params(account: TraktAccount, client: Client).void }
    def initialize(account, client)
      @account = account
      @client = client
      @last_write = T.let(nil, T.nilable(Float))
    end

    sig { returns(TraktAccount) }
    attr_reader :account

    sig { params(path: String).returns(T.untyped) }
    def get(path) = authed { |token| @client.get(path, token: token) }

    sig { params(path: String, body: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
    def post(path, body)
      space_writes
      authed { |token| @client.post(path, body, token: token) }
    end

    private

    sig { params(block: T.proc.params(token: String).returns(T.untyped)).returns(T.untyped) }
    def authed(&block)
      block.call(token)
    rescue UpstreamHttpClient::AuthError
      # Refused before it was due to run out: one refresh, one more try.
      block.call(token(force: true))
    end

    sig { params(force: T::Boolean).returns(String) }
    def token(force: false)
      @account.reload unless @account.new_record?
      return T.must(@account.access_token) if !force && fresh?

      refused = T.let(nil, T.nilable(String))
      @account.with_lock do
        # Another job may have refreshed while this one waited for the lock.
        next if !force && fresh?

        refresh_token = @account.refresh_token
        if refresh_token.blank?
          refused = "Trakt has no refresh token for this profile"
          next
        end
        begin
          Trakt::Api.store_tokens(@account, @client.refresh(refresh_token))
        rescue Client::Error => e
          raise if !e.is_a?(UpstreamHttpClient::AuthError) && e.status != 400 && e.status != 401

          refused = "Trakt no longer accepts this profile's link. Link it again in Settings › Viewing."
        end
      end
      # Outside the lock's transaction, so the raise doesn't undo the record.
      raise_unlinked!(refused) if refused
      T.must(@account.access_token)
    end

    sig { returns(T::Boolean) }
    def fresh?
      expires = @account.expires_at
      @account.access_token.present? && !expires.nil? && expires > REFRESH_AHEAD.from_now
    end

    sig { params(message: String).returns(T.noreturn) }
    def raise_unlinked!(message)
      @account.update!(state: TraktAccount::State::NeedsRelink.serialize, last_error: message, last_error_at: Time.current)
      Activity.record(source: "trakt", event: "trakt.unlinked", severity: Activity::Severity::Error, subject: @account,
        household_id: @account.household_id, summary: "Trakt stopped syncing for #{@account.profile&.name}: #{message}")
      raise Unlinked, message
    end

    sig { void }
    def space_writes
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      last = @last_write
      sleep(WRITE_SPACING - (now - last)) if last && now - last < WRITE_SPACING
      @last_write = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
    end

    sig { params(account: TraktAccount, tokens: T::Hash[String, T.untyped]).void }
    def self.store_tokens(account, tokens)
      created = tokens["created_at"] ? Time.zone.at(tokens["created_at"].to_i) : Time.current
      account.update!(access_token: tokens.fetch("access_token"), refresh_token: tokens.fetch("refresh_token"),
        expires_at: created + tokens.fetch("expires_in").to_i.seconds)
    end
  end
end
