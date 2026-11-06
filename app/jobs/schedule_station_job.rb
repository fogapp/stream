# typed: strict
# frozen_string_literal: true

# Extends one channel's schedule to three days ahead (PROPOSAL §7.7). What's
# already there never changes here; a channel that couldn't be filled says
# why on its settings and in Activity.
class ScheduleStationJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(station_id, _rebuild = false) { "station:#{station_id}" }

  # rebuild: drop what hasn't started first (the household's clock moved).
  sig { params(station_id: String, rebuild: T::Boolean).void }
  def perform(station_id, rebuild = false)
    station = Station.unscoped.find_by(id: station_id)
    return if station.nil?

    rebuild ? Stations::Scheduler.rebuild!(station) : Stations::Scheduler.extend!(station)
    problem = station.reload.last_error
    return if problem.nil?

    Activity.record(source: "live_tv", event: "station.unfilled", severity: Activity::Severity::Warn, subject: station,
      household_id: station.household_id, summary: "Channel #{station.number} #{station.name}: #{problem}")
  end
end
