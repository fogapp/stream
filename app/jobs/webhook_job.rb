# typed: strict
# frozen_string_literal: true

# Optional egress: one POST per notification to the household's webhook URL
# (Settings › General), so anything else on the LAN — a home-automation
# hub, a chat bot — can react. Best-effort; failures land on the timeline.
class WebhookJob < ApplicationJob
  extend T::Sig
  include UpstreamHttpClient

  class Error < UpstreamHttpClient::Error; end

  queue_as :default
  # One POST at a time, in order; a slow hub holds up only its own queue.
  limits_concurrency to: 1, key: "webhook"

  sig { override.returns(String) }
  def service_name = "Webhook"

  sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
  def error_class = Error

  # The operator chose this URL and expects it to be local.
  sig { override.returns(T::Boolean) }
  def allow_private_addresses? = true # rubocop:disable Stream/NoUnreviewedPrivateEgress

  sig { params(kind: String, title: String, path: T.nilable(String)).void }
  def perform(kind, title, path = nil)
    url = AppSetting.cached.webhook_url.presence
    return if url.nil?

    http_post_json(url, body: { event: kind, title: title, path: path, at: Time.current.iso8601, app: "stream" })
  rescue UpstreamHttpClient::Error => e
    Activity.record(source: "notifications", event: "webhook.failed", severity: Activity::Severity::Warn,
      summary: "Webhook #{kind}: #{e.message.truncate(160)}")
  end

  # An unreachable webhook is recorded above as webhook.failed; a crash is not.
  sig { override.params(error: Exception).returns(T::Boolean) }
  def report_death?(error) = !error.is_a?(UpstreamHttpClient::Error)
end
