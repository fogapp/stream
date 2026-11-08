# typed: strict
# frozen_string_literal: true

# Brings one linked profile's Trakt into Stream (PROPOSAL §7.4). Shares its
# concurrency key with TraktPushJob, so a pull never reads Trakt while this
# account's changes are half sent.
class TraktPullJob < ApplicationJob
  extend T::Sig

  queue_as :sync
  limits_concurrency to: 1, key: ->(account_id) { "trakt:#{account_id}" }, duration: 30.minutes

  # Trakt unreachable: try again soon; the next scheduled pull would too.
  # ActiveJob tries the last-declared handler first, and a rate limit is an
  # UpstreamHttpClient::Error too, so the narrower rule must come second.
  retry_on UpstreamHttpClient::Error, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.failed(error)
  end
  retry_on UpstreamHttpClient::RateLimitError, wait: 1.minute, attempts: 5 do |job, error|
    job.failed(error)
  end

  sig { params(account_id: String).void }
  def perform(account_id)
    account = TraktAccount.unscoped.linked.find_by(id: account_id)
    return if account.nil?

    Trakt::Pull.new(account).call
  rescue Trakt::Api::Unlinked
    nil
  rescue Trakt::Client::Error => e
    # A rate limit or a refusal is a Trakt::Client::Error too; they go on to
    # the retry_on rules above, as they always have.
    raise if e.connection? || e.status.nil? || e.status.to_i >= 500 ||
      e.is_a?(UpstreamHttpClient::RateLimitError) || e.is_a?(UpstreamHttpClient::AuthError)

    failed(e)
  end

  # Said on the account, where Settings › Viewing shows it, and in Activity.
  sig { params(error: StandardError).void }
  def failed(error)
    account = TraktAccount.unscoped.find_by(id: arguments.first)
    return if account.nil?

    account.record_error!("Couldn't sync with Trakt: #{error.message}")
    Activity.record(source: "trakt", event: "trakt.pull_failed", severity: Activity::Severity::Error, subject: account,
      household_id: account.household_id, summary: "Trakt sync for #{account.profile&.name} failed: #{error.message.truncate(200)}")
  end
end
