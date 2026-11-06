# typed: strict
# frozen_string_literal: true

# The files about to air on the Grid, made ready to stream before they're on
# (PROPOSAL §7.7): a file without its keyframe index can't be repackaged,
# so a program change onto one would wait while it's built. Only fans out —
# IndexKeyframesJob does each file, the container's index first.
class PrepareAiringsJob < ApplicationJob
  extend T::Sig

  queue_as :default

  # Further ahead than the job's own interval, so nothing airs unprepared
  # between two runs.
  AHEAD = T.let(3.hours, ActiveSupport::Duration)

  sig { void }
  def perform
    now = Time.current
    ids = MediaFile.unscoped.where(keyframes: nil, state: MediaFile::State::Probed.serialize)
      .where(id: Airing.unscoped.where(ends_at: now..).where(starts_at: ..(now + AHEAD)).select(:media_file_id))
      .pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| IndexKeyframesJob.new(id) })
  end
end
