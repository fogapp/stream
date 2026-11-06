# typed: strict
# frozen_string_literal: true

# Every linked profile's Trakt, brought into Stream (PROPOSAL §7.4). Fans
# out only.
class TraktSyncJob < ApplicationJob
  extend T::Sig

  JOB_KEY = "trakt_sync"

  queue_as :default
  limits_concurrency to: 1, key: ->(_job_run_id = nil) { JOB_KEY }

  sig { params(job_run_id: T.nilable(String)).void }
  def perform(job_run_id = nil)
    track_run(job_key: JOB_KEY, job_run_id: job_run_id) do
      ids = TraktAccount.unscoped.linked.pluck(:id)
      ActiveJob.perform_all_later(ids.map { |id| TraktPullJob.new(id) })
      "#{ids.size} Trakt account#{ids.size == 1 ? '' : 's'} queued"
    end
  end
end
