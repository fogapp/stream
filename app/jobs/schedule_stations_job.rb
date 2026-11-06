# typed: strict
# frozen_string_literal: true

# Every Grid channel's schedule, three days ahead (PROPOSAL §7.7). Only
# fans out: each channel is its own job.
class ScheduleStationsJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { void }
  def perform
    ActiveJob.perform_all_later(Station.unscoped.pluck(:id).map { |id| ScheduleStationJob.new(id) })
  end
end
