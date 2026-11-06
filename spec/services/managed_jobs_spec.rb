# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManagedJobs do
  let(:household) { Household.create!(name: "H") }

  # The console creates a Manual JobRun and hands it to the enqueue lambda;
  # the job must track THAT row. A definition that drops it leaves the Manual
  # row queued forever — blocking re-triggers for STALE_AFTER, showing a
  # phantom run in history, and (finished_at forever NULL) unprunable.
  it "passes the console's JobRun into every job it enqueues" do
    described_class::ALL.each do |definition|
      run = JobRun.create!(job_key: definition.key, household_id: household.id,
        trigger: JobRun::Trigger::Manual.serialize)

      expect { definition.enqueue.call(household, run) }.to have_enqueued_job

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:args]).to include(run.id),
        "#{definition.key}: enqueued #{job[:job]} without the job_run id #{run.id} (args: #{job[:args].inspect})"
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    end
  end

  it "resolves the console's row rather than stranding it" do
    run = JobRun.create!(job_key: PruneOperationalDataJob::JOB_KEY, household_id: household.id,
      trigger: JobRun::Trigger::Manual.serialize)

    PruneOperationalDataJob.perform_now(run.id)

    expect(run.reload.status).to eq("succeeded")
    expect(run.finished_at).to be_present
    expect(run.trigger).to eq("manual")
    expect(JobRun.where(job_key: PruneOperationalDataJob::JOB_KEY).count).to eq(1) # no shadow System row
  end
end
