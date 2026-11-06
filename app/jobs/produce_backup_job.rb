# typed: strict
# frozen_string_literal: true

# Produces one fog-backup/2 artifact into staging (fog:docs/backup-contract.md).
# Triggered by fog's POST /fog/backup (FogBackup::Trigger) or from the console
# jobs page; fog polls the JobRun this rides on and downloads the result.
class ProduceBackupJob < ApplicationJob
  extend T::Sig

  JOB_KEY = "produce_backup"

  queue_as :backup

  # Fail fast instead of the polynomial default: fog is polling for a verdict,
  # and a dump that failed once fails the same way three retries later —
  # each retry costing a full pg_dump of the archive.
  retry_on StandardError, attempts: 1

  # A second dump racing the first would double disk under staging and
  # thrash the database for nothing.
  limits_concurrency to: 1, key: "produce_backup", duration: 2.hours

  sig { params(job_run_id: T.nilable(String)).void }
  def perform(job_run_id = nil)
    run = JobRun.resolve(job_key: JOB_KEY, job_run_id: job_run_id)
    run.execute { FogBackup::Producer.new(job_run: run).call }
  end
end
