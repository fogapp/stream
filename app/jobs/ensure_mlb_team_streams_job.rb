# typed: strict
# frozen_string_literal: true

# Every club's MLB.tv stream (Mlb::TeamStreams), made once the household
# has an MLB.tv account, so a Grid channel can be given one.
class EnsureMlbTeamStreamsJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(household_id) { "mlb_team_streams:#{household_id}" }, on_conflict: :discard

  sig { params(household_id: String).void }
  def perform(household_id)
    Mlb::TeamStreams.ensure!(household_id)
  end
end
