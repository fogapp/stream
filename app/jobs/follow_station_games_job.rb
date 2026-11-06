# typed: strict
# frozen_string_literal: true

# One channel's games kept true to MLB's schedule (Stations::Games). Shares
# the channel's key with ScheduleStationJob: one changes its schedule at a
# time.
class FollowStationGamesJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(station_id) { "station:#{station_id}" }, on_conflict: :discard

  sig { params(station_id: String).void }
  def perform(station_id)
    station = Station.unscoped.find_by(id: station_id)
    Stations::Games.follow!(station) if station
  end
end
