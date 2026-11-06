# typed: strict
# frozen_string_literal: true

module FogBackup
  # Starts (or adopts) the producer job for fog's POST /fog/backup.
  #
  # Claims through JobRun.claim with the same key and stale window as the
  # console's trigger, so a fog trigger and a console trigger can never
  # double-enqueue — they contend on one lock and see each other's unfinished
  # runs. Unlike ManagedJobs.trigger! this works with no household (a fresh
  # instance being backed up before setup) and reports the already-running
  # job instead of nil, because fog's contract answer to "already producing"
  # is 409 + that job's id.
  module Trigger
    extend T::Sig

    sig { params(household: T.nilable(Household)).returns(JobRun::Claim) }
    def self.call(household: nil)
      definition = T.must(ManagedJobs.find(ProduceBackupJob::JOB_KEY))
      claim = JobRun.claim(job_key: definition.key, stale_after: definition.stale_after,
        trigger: JobRun::Trigger::System, household_id: household&.id)
      ProduceBackupJob.perform_later(claim.job_run.id) if claim.started
      claim
    end
  end
end
