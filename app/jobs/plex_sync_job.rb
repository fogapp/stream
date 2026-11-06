# typed: strict
# frozen_string_literal: true

# Keeps Stream in step with Plex while both run side by side (PROPOSAL
# §7.4): an import for every household that switched sync on. Fans out only.
class PlexSyncJob < ApplicationJob
  extend T::Sig

  JOB_KEY = "plex_sync"

  queue_as :default
  limits_concurrency to: 1, key: ->(_job_run_id = nil) { JOB_KEY }

  sig { params(job_run_id: T.nilable(String)).void }
  def perform(job_run_id = nil)
    track_run(job_key: JOB_KEY, job_run_id: job_run_id) do
      imports = PlexConnection.unscoped.where(sync_enabled: true).map do |connection|
        PlexImport.unscoped.create!(household_id: connection.household_id, dry_run: false)
      end
      ActiveJob.perform_all_later(imports.map { |import| PlexImportJob.new(import.id) })
      "#{imports.size} Plex sync#{imports.size == 1 ? '' : 's'} queued"
    end
  end
end
