# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe JobRun do
  describe ".claim" do
    def claim(**overrides)
      described_class.claim(**{ job_key: "produce_backup", stale_after: 2.hours, trigger: JobRun::Trigger::System }.merge(overrides))
    end

    it "creates a queued run when nothing is in flight" do
      result = claim

      expect(result.started).to be(true)
      expect(result.job_run).to have_attributes(job_key: "produce_backup", trigger: "system", status: "queued")
    end

    it "adopts the run already in flight rather than starting another" do
      first = claim.job_run

      again = claim(trigger: JobRun::Trigger::Manual)

      expect(again.started).to be(false)
      expect(again.job_run).to eq(first)
      expect(described_class.count).to eq(1)
    end

    it "stops deferring to a run older than the stale window" do
      claim.job_run.update!(created_at: 3.hours.ago)

      expect(claim.started).to be(true)
    end
  end
end
