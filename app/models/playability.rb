# typed: strict
# frozen_string_literal: true

# What one rung of the ladder did for one file on one kind of client:
# plays that got going on it, plays
# that failed on it the browser's way (decode, unsupported) or the
# transcoder's. Playback::Learned reads these into constraints a decision
# starts from.
class Playability < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :media_file

  # A demotion stands this long before the rung is tried again, quietly
  # (R3's probation). A browser's new major version is a new client class,
  # so it gets a try at once.
  PROBATION = T.let(30.days, ActiveSupport::Duration)

  # Failed since it last worked here, within the probation.
  sig { returns(T::Boolean) }
  def failing?
    failed = last_failed_at
    return false if failed.nil? || failed < PROBATION.ago

    succeeded = last_succeeded_at
    succeeded.nil? || succeeded < failed
  end

  sig { returns(T.nilable(PlaybackSession::FailureClass)) }
  def failure_class = PlaybackSession::FailureClass.try_deserialize(last_failure_class.to_s)
end
