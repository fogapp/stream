# typed: strict
# frozen_string_literal: true

# Every Grid channel with teams on it, its games kept true to MLB's
# schedule (Stations::Games): a game over ends its slot, one still going is
# given more time, a schedule that changed rebuilds. Only fans out.
class FollowGamesJob < ApplicationJob
  extend T::Sig

  queue_as :control

  sig { void }
  def perform
    households = MlbSetting.unscoped.select(:household_id)
    ids = Station.unscoped.where(household_id: households, live_stream_id: nil).where.not(mlb_team_ids: []).pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| FollowStationGamesJob.new(id) })
  end
end
