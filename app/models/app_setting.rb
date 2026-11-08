# typed: strict
# frozen_string_literal: true

# Instance-level settings that belong to the operator, not to a household.
#
# A singleton row (unique index on `true`). Read on hot paths, so it carries a
# short per-process memo like hub's AppSetting — busted on commit and in specs.
class AppSetting < ApplicationRecord
  extend T::Sig

  CACHE_TTL = T.let(30.seconds, ActiveSupport::Duration)

  sig { returns(AppSetting) }
  def self.current
    first || create!
  rescue ActiveRecord::RecordNotUnique
    T.must(first)
  end

  sig { returns(AppSetting) }
  def self.cached
    cached_at = @cached_at
    memo = @cached
    return memo if memo && cached_at && cached_at > CACHE_TTL.ago

    @cached = T.let(current, T.nilable(AppSetting))
    @cached_at = T.let(Time.current, T.nilable(ActiveSupport::TimeWithZone))
    T.must(@cached)
  end

  sig { void }
  def self.bust_cache!
    @cached = nil
    @cached_at = nil
  end

  after_commit { self.class.bust_cache! }

  # The outgoing webhook's address (Settings › General) usually carries its
  # secret in the path (Home Assistant's webhook id): kept encrypted, and
  # never serialized back — only that it's set, and where it goes.
  encrypts :webhook_url

  validate :known_time_zone
  validate :webhook_url_is_web, if: :webhook_url_changed?
  validate :ntfy_url_is_web, if: :ntfy_url_changed?
  validate :optimize_settings_in_range

  # Settings › General's limits, each with what the form says when one's
  # outside them.
  OPTIMIZE_HEIGHTS = T.let([ 720, 1080, 2160 ].freeze, T::Array[Integer])

  # Where the webhook goes, without the path that is its secret.
  sig { returns(T.nilable(String)) }
  def webhook_host
    url = webhook_url
    return nil if url.blank?

    uri = URI.parse(url)
    uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
  rescue URI::InvalidURIError
    nil
  end

  # Whether optimized versions may be encoded now (PROPOSAL §5.5): inside
  # the quiet hours, which may wrap past midnight. Equal start and end mean
  # any time. Hours on the household's clock, like everything else it sets.
  sig { params(time: ActiveSupport::TimeWithZone).returns(T::Boolean) }
  def quiet_hours?(time = Time.current)
    start = optimize_quiet_start_hour
    finish = optimize_quiet_end_hour
    return true if start == finish

    hour = time.in_time_zone(zone).hour
    start < finish ? hour >= start && hour < finish : hour >= start || hour < finish
  end

  # When quiet hours next begin and, from then, end; nil when every hour
  # is quiet. Inside quiet hours, the start is the one already passed.
  sig { params(time: ActiveSupport::TimeWithZone).returns(T.nilable([ ActiveSupport::TimeWithZone, ActiveSupport::TimeWithZone ])) }
  def quiet_window(time = Time.current)
    start = optimize_quiet_start_hour
    finish = optimize_quiet_end_hour
    return nil if start == finish

    local = time.in_time_zone(zone)
    begins = local.change(hour: start)
    begins -= 1.day if quiet_hours?(time) && begins > local
    begins += 1.day if !quiet_hours?(time) && begins <= local
    length = (finish - start) % 24
    [ begins, begins + length.hours ]
  end

  # The household's wall clock (Settings › General): what the Grid's Sunday
  # 8pm means. Unset, the server's own.
  sig { returns(ActiveSupport::TimeZone) }
  def zone = (time_zone.presence && ActiveSupport::TimeZone[time_zone.to_s]) || Time.zone

  sig { returns(Integer) }
  def optimize_budget_bytes = optimize_budget_gb * 1.gigabyte

  private

  sig { void }
  def webhook_url_is_web
    url = webhook_url
    return if url.nil?

    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end
    return if uri.is_a?(URI::HTTP) && uri.host.present?

    errors.add(:base, "The webhook's address starts with http:// or https://")
  end

  sig { void }
  def ntfy_url_is_web
    url = ntfy_url
    errors.add(:base, "ntfy's address starts with http:// or https://") if url && !url.match?(%r{\Ahttps?://\S+\z})
  end

  # A blank transcode cap is the encoder's own default (Encoders.default_cap).
  sig { void }
  def optimize_settings_in_range
    cap = max_video_transcodes
    errors.add(:base, "The limit must be between 1 and 8") if cap && !cap.between?(1, 8)
    if [ optimize_quiet_start_hour, optimize_quiet_end_hour ].any? { |hour| hour.nil? || !hour.between?(0, 23) }
      errors.add(:base, "Quiet hours run from one hour of the day (0–23) to another")
    end
    errors.add(:base, "Optimized versions are 720p, 1080p or 2160p") unless OPTIMIZE_HEIGHTS.include?(optimize_max_height)
    budget = optimize_budget_gb
    errors.add(:base, "The space for optimized versions is between 1 and 100000 GB") if budget.nil? || !budget.between?(1, 100_000)
  end

  sig { void }
  def known_time_zone
    errors.add(:time_zone, "isn't a time zone Stream knows") if time_zone.present? && ActiveSupport::TimeZone[time_zone.to_s].nil?
  end
end
