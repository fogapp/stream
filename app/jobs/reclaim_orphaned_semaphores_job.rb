# typed: strict
# frozen_string_literal: true

# Releases concurrency semaphores whose holder no longer exists.
#
# Several jobs hold long semaphore durations on purpose — a VOD download runs
# for hours (6h), a batch of transcriptions longer (12h), a terabyte NAS
# relocation can take a day or two (48h) — because an expired semaphore lets
# a duplicate start against the same work. The cost of that choice appears
# when a worker dies without releasing: nothing cleared the semaphore until
# the duration ran out, so a crashed relocation blocked its own re-run for up
# to two days, on exactly the hardware (home servers, power loss) this system
# is designed for.
#
# A semaphore is orphaned when no unfinished, un-failed job carries its
# concurrency key *and* a permit is still out (value below the job's limit).
# Failed jobs count as non-holders: they sit in failed_executions awaiting a
# decision, and blocking re-enqueues on their behalf is the lockout this job
# exists to end. A semaphore whose permits are all back is not orphaned: Solid
# Queue leaves the row in place after a normal finish and only deletes it once
# it expires, so every job that completed within its duration leaves one
# behind. Counting those reported every healthy run as a crash.
class ReclaimOrphanedSemaphoresJob < ApplicationJob
  extend T::Sig

  queue_as :control
  limits_concurrency to: 1, key: -> { "reclaim_orphaned_semaphores" }

  sig { void }
  def perform
    held = SolidQueue::Job.where(finished_at: nil)
      .where.not(concurrency_key: nil)
      .where.not(id: SolidQueue::FailedExecution.select(:job_id))
      .select(:concurrency_key)

    leaked = SolidQueue::Semaphore.where.not(key: held).pluck(:id, :key, :value)
      .select { |_id, key, value| value < limit_for(key) }
      .map(&:first)
    return if leaked.empty?

    released = SolidQueue::Semaphore.where(id: leaked).where.not(key: held).delete_all
    return if released.zero?

    # Warn, not info: every reclaim here means a job died hard enough to skip
    # its own cleanup, and someone should know that happened.
    Activity.record(source: "jobs", event: "semaphores.reclaimed",
      severity: Activity::Severity::Warn,
      summary: "Released #{released} orphaned concurrency semaphore#{released == 1 ? '' : 's'} " \
               "left behind by jobs that died without finishing")
  end

  private

  # Keys are "<group>/<key>", and no job here names a group of its own, so
  # the group is the job's class. One that's gone is taken to have allowed one.
  sig { params(key: String).returns(Integer) }
  def limit_for(key)
    group = key.split("/", 2).first
    job_class = ApplicationJob.descendants.find { |job| job.name == group }
    job_class ? T.unsafe(job_class).concurrency_limit || 1 : 1
  end
end
