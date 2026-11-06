# typed: strict
# frozen_string_literal: true

# "New episode of Severance" (PROPOSAL §7.4): tells each profile, on its
# own ntfy topic, what's arrived in a show it's watching or a channel it
# subscribes to. Run a few minutes after the first file lands, so a
# season arriving at once is one message; each thing is told once.
class NotifyArrivalsJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(kind, id) { "notify_arrivals:#{kind}:#{id}" }

  WAIT = T.let(10.minutes, ActiveSupport::Duration)
  # A show counts as being watched if an episode was finished this recently.
  WATCHING = T.let(180.days, ActiveSupport::Duration)
  # Only what arrived lately is news.
  FRESH = T.let(3.days, ActiveSupport::Duration)

  sig { params(kind: String, id: String).void }
  def perform(kind, id)
    base = NtfyClient.base_url
    return if base.nil?

    case kind
    when "show" then show(base, id)
    when "channel" then channel(base, id)
    end
  end

  private

  sig { params(base: String, show_id: String).void }
  def show(base, show_id)
    show = Show.unscoped.find_by(id: show_id)
    return if show.nil?

    arrived = Episode.where(show_id: show.id)
      .where(id: Edition.where(playable_type: "Episode", created_at: FRESH.ago..).select(:playable_id)).order(:season_number, :episode_number).to_a
    return if arrived.empty?

    finished = WatchState.where(playable_type: "Episode", playable_id: Episode.where(show_id: show.id).select(:id), completed_at: WATCHING.ago..)
    Profile.unscoped.where(id: finished.select(:profile_id), notify_new_episodes: true).where.not(ntfy_topic: [ nil, "" ]).find_each do |profile|
      fresh = untold(profile, arrived)
      next if fresh.empty?

      first = T.cast(fresh.first, Episode)
      message = fresh.size == 1 ? [ first.code, first.title ].compact.join(" · ") : "#{fresh.size} new episodes"
      tell(base, profile, "New in #{show.title}", message, "/show/#{show.id}", fresh)
    end
  end

  sig { params(base: String, channel_id: String).void }
  def channel(base, channel_id)
    channel = Channel.unscoped.find_by(id: channel_id)
    return if channel.nil?

    arrived = Video.unscoped.where(channel_id: channel.id)
      .where(id: Edition.where(playable_type: "Video", created_at: FRESH.ago..).select(:playable_id)).order(upload_date: :desc).to_a
    return if arrived.empty?

    subscribers = ChannelSubscription.where(channel_id: channel.id).select(:profile_id)
    Profile.unscoped.where(id: subscribers, notify_subscriptions: true).where.not(ntfy_topic: [ nil, "" ]).find_each do |profile|
      fresh = untold(profile, arrived)
      next if fresh.empty?

      message = fresh.size == 1 ? T.cast(fresh.first, Video).title : "#{fresh.size} new videos"
      tell(base, profile, "New from #{channel.title}", message, "/channel/#{channel.id}", fresh)
    end
  end

  sig { params(profile: Profile, items: T::Array[T.any(Episode, Video)]).returns(T::Array[T.any(Episode, Video)]) }
  def untold(profile, items)
    told = ProfileNotice.where(profile: profile, subject_type: items.first.class.name, subject_id: items.map(&:id)).pluck(:subject_id).to_set
    items.reject { |item| told.include?(item.id) }
  end

  sig { params(base: String, profile: Profile, title: String, message: String, path: String, items: T::Array[T.any(Episode, Video)]).void }
  def tell(base, profile, title, message, path, items)
    host = ENV["STREAM_HOST"].presence
    NtfyClient.new(base_url: base, topic: profile.ntfy_topic.to_s).publish(title: title, message: message, click: host ? "https://#{host}#{path}" : nil)
    now = Time.current
    rows = items.map { |item| { profile_id: profile.id, subject_type: item.class.name, subject_id: item.id, created_at: now } }
    ProfileNotice.insert_all(rows, unique_by: :index_profile_notices_uniqueness) # rubocop:disable Rails/SkipsModelValidations
  rescue UpstreamHttpClient::Error => e
    Activity.record(source: "notifications", event: "push.failed", severity: Activity::Severity::Warn, household_id: profile.household_id,
      summary: "Couldn't tell #{profile.name} about #{title}: #{e.message.truncate(200)}")
  end
end
