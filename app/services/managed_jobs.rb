# typed: strict
# frozen_string_literal: true

# Registry of jobs the console can trigger and show history for
# (hub:app/services/managed_jobs.rb). Keys come from the jobs' own JOB_KEY
# constants so the registry and the jobs can't drift.
module ManagedJobs
  extend T::Sig

  # A queued/running row older than this is presumed orphaned by a dead
  # process, so it stops blocking manual triggers (hub's STALE_AFTER). Jobs
  # whose honest runtime exceeds it say so per-definition below.
  STALE_AFTER = T.let(15.minutes, ActiveSupport::Duration)

  # Every enqueue lambda must hand job_run.id to the job it enqueues, and the
  # job must pass it through to track_run. The row the console created IS
  # the row the run resolves — an ignored job_run leaves a Manual row queued
  # forever: it blocks re-triggers for stale_after, shows a phantom run beside
  # the real one, and (finished_at forever NULL) is unprunable.
  class Definition < T::Struct
    const :key, String
    const :label, String
    const :description, String
    const :enqueue, T.proc.params(household: Household, job_run: JobRun).void
    const :stale_after, ActiveSupport::Duration, default: STALE_AFTER
  end

  ALL = T.let([
    Definition.new(
      key: ScanAllLibrariesJob::JOB_KEY,
      label: "Scan all libraries",
      description: "Walk every library folder for new, changed and vanished files, and probe what's new.",
      enqueue: ->(_household, job_run) { ScanAllLibrariesJob.perform_later(job_run.id) }
    ),
    Definition.new(
      key: PruneOperationalDataJob::JOB_KEY,
      label: "Prune operational data",
      description: "Age out activity, job runs, and read notifications past their retention windows.",
      enqueue: ->(_household, job_run) { PruneOperationalDataJob.perform_later(job_run.id) }
    ),
    Definition.new(
      key: PlayabilitySweepJob::JOB_KEY,
      label: "Try every format",
      description: "Play one file of each format every way the server can, so a format that won't play is found before anyone presses Play.",
      enqueue: ->(_household, job_run) { PlayabilitySweepJob.perform_later(job_run.id) }
    ),
    Definition.new(
      key: TraktSyncJob::JOB_KEY,
      label: "Sync with Trakt",
      description: "Bring every linked profile's Trakt history, ratings and Watch later into Stream.",
      enqueue: ->(_household, job_run) { TraktSyncJob.perform_later(job_run.id) }
    ),
    Definition.new(
      key: PlexSyncJob::JOB_KEY,
      label: "Sync with Plex",
      description: "Import what was watched in Plex since last time, for every household that turned sync on.",
      enqueue: ->(_household, job_run) { PlexSyncJob.perform_later(job_run.id) }
    ),
    Definition.new(
      key: ProduceBackupJob::JOB_KEY,
      label: "Produce backup artifact",
      description: "Build a full fog-backup/2 artifact (database dump + file state) into staging for fog to collect.",
      enqueue: ->(_household, job_run) { ProduceBackupJob.perform_later(job_run.id) },
      # Dumping takes as long as it takes; presuming it dead at minute
      # sixteen would let a duplicate dump queue up.
      stale_after: 2.hours
    )
  ].freeze, T::Array[Definition])

  sig { params(key: String).returns(T.nilable(Definition)) }
  def self.find(key) = ALL.find { |definition| definition.key == key }

  # The one way to manually trigger a managed job — console and MCP both call
  # this. Returns the created JobRun, or nil when the job is already running
  # (JobRun.claim holds the lock that makes check-and-create one step).
  sig { params(definition: Definition, household: Household).returns(T.nilable(JobRun)) }
  def self.trigger!(definition:, household:)
    claim = JobRun.claim(job_key: definition.key, stale_after: definition.stale_after,
      trigger: JobRun::Trigger::Manual, household_id: household.id)
    return nil unless claim.started

    definition.enqueue.call(household, claim.job_run)
    claim.job_run
  end
end
