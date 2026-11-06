# typed: strict
# frozen_string_literal: true

# Notification writer + optional ntfy push. In-app rows use the hub
# idempotency shape (dedupe_key + insert_all(unique_by:)) so callers can
# blindly re-emit. ntfy is reached directly at NTFY_URL on the fog network —
# fog has no notification API for apps by design (fog convention).
module Notifier
  extend T::Sig

  sig do
    params(
      users: T::Array[User],
      kind: String,
      title: String,
      dedupe_key: String,
      icon: T.nilable(String),
      path: T.nilable(String),
      push: T::Boolean
    ).returns(Integer)
  end
  def self.notify(users:, kind:, title:, dedupe_key:, icon: nil, path: nil, push: false)
    now = Time.current
    rows = users.map do |user|
      {
        user_id: user.id, household_id: user.household_id,
        kind: kind, icon: icon, title: title, path: path,
        dedupe_key: dedupe_key, created_at: now
      }
    end
    return 0 if rows.empty?

    result = Notification.insert_all(rows, unique_by: %i[user_id dedupe_key]) # rubocop:disable Rails/SkipsModelValidations
    inserted = result.rows.length
    # Enqueued, never inline: push blocks on a network round trip (up to 6s
    # of open+read timeout), and a caller on a request path shouldn't pay it
    # — the in-app row above is the durable record either way.
    PushNotificationJob.perform_later(title: title, kind: kind) if push && inserted.positive?
    WebhookJob.perform_later(kind, title, path) if inserted.positive? && AppSetting.cached.webhook_url.present?
    inserted
  end

  # Called by PushNotificationJob; public so the job can reach it without
  # send. Best-effort by design, but recorded when it fails — a push channel
  # that silently died would be discovered exactly when someone needed it.
  sig { params(title: String, kind: String).void }
  def self.push_ntfy(title:, kind:)
    base = NtfyClient.base_url
    return if base.nil?

    NtfyClient.new(base_url: base, topic: ENV["NTFY_TOPIC"].presence || "stream")
      .publish(title: "Stream: #{kind}", message: title)
  rescue StandardError => e
    # Push is best-effort; the in-app row is the durable record. Warn-level
    # activity rather than a log line, per the house rule — silent failure
    # is the enemy, and container logs rotate. A refusal (a misconfigured
    # topic, an ntfy that wants auth) arrives here as a typed error too.
    said = e.is_a?(UpstreamHttpClient::Error) ? e.message : "#{e.class}: #{e.message}"
    Activity.record(source: "notifications", event: "push.failed",
      severity: Activity::Severity::Warn,
      summary: "ntfy push failed: #{said.to_s.truncate(160)} — check NTFY_URL and topic auth")
  end
end
