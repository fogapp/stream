# typed: strict
# frozen_string_literal: true

# The hourly safety net (PROPOSAL §5.1): the NAS never tells Stream what
# changed, so every library is rescanned on a timer. Fans out only.
class ScanAllLibrariesJob < ApplicationJob
  extend T::Sig

  JOB_KEY = "scan_all_libraries"

  queue_as :default
  limits_concurrency to: 1, key: ->(_job_run_id = nil) { JOB_KEY }

  sig { params(job_run_id: T.nilable(String)).void }
  def perform(job_run_id = nil)
    track_run(job_key: JOB_KEY, job_run_id: job_run_id) do
      ids = Library.unscoped.pluck(:id)
      ActiveJob.perform_all_later(ids.map { |id| ScanLibraryJob.new(id) })
      "#{ids.size} librar#{ids.size == 1 ? 'y' : 'ies'} queued"
    end
  end
end
