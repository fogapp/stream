# typed: strict
# frozen_string_literal: true

# Keeps the operational record from outliving its usefulness.
#
# Stream writes a lot about itself, and it writes most of it on a timer: every
# scan, every analysis step, every playback session. A couple of million rows
# a year on a machine that is somebody's NAS. Nothing goes wrong suddenly; the
# dashboard just gets slower every month until the timeline is the most
# expensive page in the app and nobody remembers why.
#
# The windows below are a judgement about how long each kind of row can still
# answer a question:
#
#   - An error is the forensic record. "This source broke in March" is a
#     question people genuinely ask, so errors outlive everything else.
#   - Info and warnings are for reading this week. After three months they are
#     the texture of normal operation, not evidence.
#   - A job run describes one execution. After a month the thing it worked
#     on carries its own record of what happened, and the row is redundant.
#   - A transcode run that went fine is noise after a fortnight; one that
#     failed is evidence for a season.
#   - A notification that has been read has done its job. An unread one has
#     not, so this never touches those, however old they are.
#
# Deleting is done in batches with delete_all: these tables have no callbacks
# worth running and no dependents, and a single unbounded DELETE over a
# million rows is how a nightly tidy-up becomes a lock-held outage.
class PruneOperationalDataJob < ApplicationJob
  extend T::Sig

  JOB_KEY = "prune_operational_data"

  # Rows per DELETE. Small enough that each statement is short, large enough
  # that a year of backlog drains in one run rather than one row at a time.
  BATCH = 5_000
  # A backstop, not a policy: if a table is somehow so far behind that it
  # cannot be drained in one night, stop and let the next run continue rather
  # than holding a connection until morning.
  MAX_BATCHES_PER_TABLE = 200

  class Retention < T::Struct
    const :label, String
    const :window, ActiveSupport::Duration
    # Takes the cutoff so the scope can decide what "older than" means for it —
    # job_runs measure it against finishing, everything else against creation.
    const :scope, T.proc.params(cutoff: ActiveSupport::TimeWithZone).returns(T.untyped)
  end

  POLICIES = T.let([
    Retention.new(
      label: "activity", window: 90.days,
      scope: ->(cutoff) {
        ActivityEntry.where(created_at: ...cutoff)
          .where.not(severity: Activity::Severity::Error.serialize)
      }
    ),
    Retention.new(
      label: "activity errors", window: 1.year,
      scope: ->(cutoff) {
        ActivityEntry.where(created_at: ...cutoff)
          .where(severity: Activity::Severity::Error.serialize)
      }
    ),
    Retention.new(
      # Finished only: a queued or running row is either live or orphaned, and
      # ManagedJobs::STALE_AFTER is what decides which. Deleting one out from
      # under a running job would make the console lose track of it.
      label: "job runs", window: 30.days,
      scope: ->(cutoff) { JobRun.where(finished_at: ...cutoff) }
    ),
    Retention.new(
      # One row per ffmpeg run. A run that
      # went fine says nothing after a fortnight; one that failed is the
      # evidence for the Playback page, kept a season. Finished only: a live
      # remote run is a node's work in hand.
      label: "transcode runs", window: 14.days,
      scope: ->(cutoff) { TranscodeRun.where(finished_at: ...cutoff, failure: nil) }
    ),
    Retention.new(
      label: "failed transcode runs", window: 90.days,
      scope: ->(cutoff) { TranscodeRun.failed.where(finished_at: ...cutoff) }
    ),
    Retention.new(
      label: "read notifications", window: 90.days,
      scope: ->(cutoff) { Notification.where(created_at: ...cutoff).where.not(read_at: nil) }
    )
  ].freeze, T::Array[Retention])

  queue_as :default
  limits_concurrency to: 1, key: ->(_job_run_id = nil) { "prune_operational_data" }

  sig { params(job_run_id: T.nilable(String)).void }
  def perform(job_run_id = nil)
    track_run(job_key: JOB_KEY, job_run_id: job_run_id) do
      now = Time.current
      deleted = POLICIES.to_h { |policy| [ policy.label, prune(policy, now: now) ] }
      total = deleted.values.sum

      next "nothing to prune" if total.zero?

      Activity.record(source: "maintenance", event: "prune.completed",
        summary: "Pruned #{total} operational row#{total == 1 ? '' : 's'}: " \
                 "#{deleted.reject { |_, count| count.zero? }.map { |label, count| "#{count} #{label}" }.join(', ')}",
        payload: deleted)

      "#{total} row#{total == 1 ? '' : 's'} pruned"
    end
  end

  private

  # `where(id: ... limit)` rather than `scope.limit(n).delete_all`, which
  # Postgres will not accept — DELETE takes no LIMIT, so the bound has to ride
  # in on a subselect.
  sig { params(policy: Retention, now: ActiveSupport::TimeWithZone).returns(Integer) }
  def prune(policy, now:)
    scope = policy.scope.call(now - policy.window)
    model = scope.model
    deleted = T.let(0, Integer)

    MAX_BATCHES_PER_TABLE.times do
      batch = model.where(id: scope.limit(BATCH).select(:id)).delete_all
      deleted += batch
      break if batch < BATCH
    end

    deleted
  end
end
