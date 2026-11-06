# typed: strict
# frozen_string_literal: true

# Settings shapes: credentials are never serialized back — only whether they
# are present.
module SettingsSerializer
  extend T::Sig

  # `profiles` are those whose topics an admin may see; an empty list for
  # anyone else, since on an open ntfy a topic's name is all it takes to read it.
  sig { params(setting: AppSetting, profiles: T::Array[Profile]).returns(T::Hash[Symbol, T.untyped]) }
  def self.general_json(setting, profiles: [])
    {
      webhook_url: setting.webhook_url,
      # Where profiles' pushes go (each profile picks its own topic), and
      # each topic, so whoever subscribes knows what to subscribe to.
      ntfy_url: setting.ntfy_url,
      ntfy_topics: profiles.map { |profile| ntfy_topic_json(profile) },
      # The transcode limit and what it's measured against (PROPOSAL §6.3).
      max_video_transcodes: setting.max_video_transcodes,
      encoder: Playback::Encoders.kind, default_max_video_transcodes: Playback::Encoders.default_cap,
      avx2: Playback::Encoders.avx2?,
      tone_mapping: Playback::Encoders::Profile.local(Playback::Encoders.kind).tonemap_name,
      # Optimized versions (PROPOSAL §5.5).
      optimize_automatically: setting.optimize_automatically, optimize_paused: setting.optimize_paused,
      optimize_quiet_start_hour: setting.optimize_quiet_start_hour, optimize_quiet_end_hour: setting.optimize_quiet_end_hour,
      optimize_max_height: setting.optimize_max_height, optimize_budget_gb: setting.optimize_budget_gb,
      fetch_trailers: setting.fetch_trailers,
      # The household's clock (the Grid's schedules), and the server's when unset.
      time_zone: setting.time_zone, server_time_zone: Time.zone.tzinfo.name,
      time_zones: ActiveSupport::TimeZone.all.map { |zone| { name: zone.tzinfo.name, label: zone.to_s } }.uniq { |zone| zone[:name] }
    }
  end

  # What ntfy pushes to a profile's topic: Grid reminders always (the
  # profile asked for each one), new episodes and new videos as it chose.
  sig { params(profile: Profile).returns(T::Hash[Symbol, T.untyped]) }
  def self.ntfy_topic_json(profile)
    pushes = []
    pushes << "new_episodes" if profile.notify_new_episodes
    pushes << "new_videos" if profile.notify_subscriptions
    pushes << "live_reminders"
    { profile_id: profile.id, profile: profile.name, topic: profile.ntfy_topic, pushes: pushes }
  end
end
