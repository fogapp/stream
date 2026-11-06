# typed: strict
# frozen_string_literal: true

# "Starting now on 4" (PROPOSAL §7.7): a program someone asked to be reminded
# of is about to air. In the app for the user who asked, and on the
# profile's ntfy topic when it has one. Told once.
class RemindAiringJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(reminder_id) { "airing_reminder:#{reminder_id}" }

  sig { params(reminder_id: String).void }
  def perform(reminder_id)
    reminder = AiringReminder.find_by(id: reminder_id)
    airing = reminder&.airing
    station = airing&.station
    user = reminder&.user
    profile = reminder&.profile
    return if reminder.nil? || airing.nil? || station.nil? || user.nil? || profile.nil? || reminder.notified_at
    # Moved (a rebuild) or long over: nothing to say.
    return if airing.ends_at <= Time.current

    title = "#{program(airing)} starts at #{airing.starts_at.in_time_zone(AppSetting.cached.zone).strftime('%-l:%M%P')} on #{station.number} #{station.name}"
    path = "/live/#{station.number}"
    Notifier.notify(users: [ user ], kind: "live_reminder", title: title, path: path, dedupe_key: "airing_reminder:#{reminder.id}")
    push(profile, title, path)
    reminder.update!(notified_at: Time.current)
  end

  private

  sig { params(airing: Airing).returns(String) }
  def program(airing)
    return airing.program_title.to_s if airing.game?

    playable = airing.playable
    case playable
    when Episode then [ playable.show&.title, playable.code ].compact.join(" ")
    when Movie then playable.title
    else "A program"
    end
  end

  sig { params(profile: Profile, title: String, path: String).void }
  def push(profile, title, path)
    base = NtfyClient.base_url
    return if base.nil? || profile.ntfy_topic.blank?

    host = ENV["STREAM_HOST"].presence
    NtfyClient.new(base_url: base, topic: profile.ntfy_topic.to_s).publish(title: "Grid", message: title, click: host ? "https://#{host}#{path}" : nil)
  rescue UpstreamHttpClient::Error => e
    Activity.record(source: "notifications", event: "push.failed", severity: Activity::Severity::Warn, household_id: profile.household_id,
      summary: "Couldn't remind #{profile.name}: #{e.message.truncate(200)}")
  end
end
