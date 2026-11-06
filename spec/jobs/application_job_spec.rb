# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationJob do
  # A validation failure is deterministic: retrying re-runs the job's full
  # cost to report the same bug, and delays the dead-letter signal by the
  # cumulative backoff.
  class DeterministicFailureJob < ApplicationJob
    def perform
      record = Household.new # name is required
      record.save!
    end
  end

  class TransientFailureJob < ApplicationJob
    def perform
      raise ActiveRecord::ConnectionNotEstablished, "db blip"
    end
  end

  class FlakyTrackedJob < ApplicationJob
    cattr_accessor :fail_next

    def perform
      track_run(job_key: "flaky_tracked") do
        raise "boom" if self.class.fail_next

        "ok"
      end
    end
  end

  # The model comment promises "a retry flips the same row back to running" —
  # that only holds if the retry carries the row's id. A fetch that failed
  # twice then succeeded used to read as three separate runs in the console.
  it "reports a retry into the row the first attempt created" do
    FlakyTrackedJob.fail_next = true
    job = FlakyTrackedJob.new
    job.perform_now # fails; retry_on schedules attempt 2

    serialized = job.serialize
    expect(serialized["stream_job_run_id"]).to eq(JobRun.sole.id)

    FlakyTrackedJob.fail_next = false
    ActiveJob::Base.deserialize(serialized).perform_now

    run = JobRun.sole # one logical run, not one row per attempt
    expect(run.status).to eq("succeeded")
    expect(run.error).to be_nil
  end

  it "dead-letters a validation failure immediately instead of retrying it" do
    expect { DeterministicFailureJob.perform_now }.not_to raise_error

    expect(DeterministicFailureJob).not_to have_been_enqueued
    expect(ActivityEntry.errors.where(event: "job.dead").count).to eq(1)
  end

  it "still retries transient failures" do
    expect { TransientFailureJob.perform_now }.not_to raise_error

    expect(TransientFailureJob).to have_been_enqueued # attempt 2 scheduled
    expect(ActivityEntry.errors.where(event: "job.dead")).to be_empty
  end
end
