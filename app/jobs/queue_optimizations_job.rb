# typed: strict
# frozen_string_literal: true

# The nightly pass's list (PROPOSAL §5.5): files no device seen this month
# plays without converting its video get an optimized version queued, while
# there's room in the budget, and so do files some device would convert
# that are about to be wanted (docs/PERF_PROPOSAL.md › P20): a Grid
# program in the next three days, so changing to its channel is never a
# conversion, and the next episode of a show someone is watching. Those are
# stamped with when they're needed, and the transcoder encodes the soonest
# first, in quiet hours.
class QueueOptimizationsJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: "queue-optimizations"

  # A show counts as being watched if someone played an episode this recently.
  WATCHING = T.let(30.days, ActiveSupport::Duration)

  sig { void }
  def perform
    setting = AppSetting.current
    return unless setting.optimize_automatically
    return if OptimizedVersion.bytes_used >= setting.optimize_budget_bytes

    Household.find_each do |household|
      needed = Current.set(household: household) { wanted_soon(household) }
      rows = Playback::Report.needing_conversion(household).select { |row| row[:all_devices] || needed.key?(row[:media_file_id]) }
      existing = OptimizedVersion.unscoped.where(media_file_id: rows.pluck(:media_file_id)).index_by(&:media_file_id)
      rows.each do |row|
        at, why = needed[row[:media_file_id]]
        reason = (why || OptimizedVersion::Reason::AllDevices).serialize
        version = existing[row[:media_file_id]]
        # A skipped file has a row, so it is never queued again.
        if version.nil?
          OptimizedVersion.create!(household_id: household.id, media_file_id: row[:media_file_id],
            origin: OptimizedVersion::Origin::Automatic.serialize, needed_at: at, reason: reason)
        elsif version.state_enum == OptimizedVersion::State::Queued && version.origin_enum == OptimizedVersion::Origin::Automatic &&
              (moved?(version.needed_at, at) || version.reason != reason)
          # Airings move and viewers move on: re-stamped every pass.
          version.update!(needed_at: at, reason: reason)
        end
      end
    end
  end

  private

  # Whether a stamp changed: one already due stays as it was while it's
  # still due. "Now" is a new time every pass, and re-stamping every airing
  # under way and every next episode with it was a write per row an hour
  # (Glass, 2026-10-20) that changed no file's place in the queue.
  sig { params(was: T.nilable(ActiveSupport::TimeWithZone), now: T.nilable(ActiveSupport::TimeWithZone)).returns(T::Boolean) }
  def moved?(was, now)
    return was != now if was.nil? || now.nil?

    due = Time.current
    !(was <= due && now <= due) && was != now
  end

  # The files wanted soon, when, and why: each airing's start, and now for
  # the next episode of every show a profile has been watching.
  sig do
    params(household: Household)
      .returns(T::Hash[String, [ ActiveSupport::TimeWithZone, OptimizedVersion::Reason ]])
  end
  def wanted_soon(household)
    needed = T.let({}, T::Hash[String, [ ActiveSupport::TimeWithZone, OptimizedVersion::Reason ]])
    # A game has no file to make ready.
    Airing.unscoped.where(household_id: household.id).where("ends_at > ?", Time.current).where.not(media_file_id: nil)
      .group(:media_file_id).minimum(:starts_at)
      .each { |id, starts| needed[id] = [ [ starts, Time.current ].max, OptimizedVersion::Reason::Airing ] }
    # Next up for every profile from one read of the shows they're
    # watching: the episodes once, every profile's states of them once.
    profiles = Profile.unscoped.where(household_id: household.id).to_a
    watching = WatchState.where(profile_id: profiles.map(&:id), playable_type: "Episode", last_watched_at: WATCHING.ago..)
      .joins("JOIN episodes ON episodes.id = watch_states.playable_id").distinct.pluck(:profile_id, "episodes.show_id")
      .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    return needed if watching.empty?

    episodes = Episode.where(show_id: watching.values.flatten.uniq, id: Viewing::Catalog.readable_ids("Episode"))
      .reorder(:season_number, :episode_number, :air_date).to_a
    by_show = episodes.group_by(&:show_id)
    states = WatchState.where(profile_id: watching.keys, playable_type: "Episode", playable_id: episodes.map(&:id)).to_a
      .group_by(&:profile_id).transform_values { |rows| rows.index_by(&:playable_id) }
    picks = profiles.flat_map do |profile|
      watching.fetch(profile.id, []).filter_map { |show_id| Viewing::NextUp.pick(by_show.fetch(show_id, []), states.fetch(profile.id, {})) }
    end
    Edition.where(playable_type: "Episode", playable_id: picks.map { |pick| pick.episode.id }).pluck(:media_file_id)
      .each { |id| needed[id] = [ Time.current, OptimizedVersion::Reason::NextUp ] }
    needed
  end
end
