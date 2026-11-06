# typed: strict
# frozen_string_literal: true

# Sends one linked profile's waiting changes to Trakt (PROPOSAL §7.4). One
# at a time per account: Trakt allows a person one write a second.
class TraktPushJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(account_id) { "trakt:#{account_id}" }, duration: 10.minutes

  # Trakt down or busy: the changes wait in the outbox for the next try.
  retry_on UpstreamHttpClient::Error, wait: :polynomially_longer, attempts: 8

  sig { params(account_id: String).void }
  def perform(account_id)
    account = TraktAccount.unscoped.linked.find_by(id: account_id)
    return if account.nil?

    Trakt::Push.new(account).call
  rescue Trakt::Api::Unlinked
    # Recorded on the account; nothing more to send until it's linked again.
    nil
  end
end
