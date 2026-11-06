# typed: false
# frozen_string_literal: true

require "rails_helper"

# The windows are a policy, so they are asserted rather than inferred: a
# change to one of them should show up here as a deliberate edit, not as a
# test that quietly still passes.
RSpec.describe PruneOperationalDataJob do
  let(:household) { Household.create!(name: "H") }

  def window_for(label)
    described_class::POLICIES.find { |policy| policy.label == label }.window
  end

  def entry(severity:, age:)
    ActivityEntry.create!(household: household, source: "ingest", event: "e",
      summary: "s", severity: severity, created_at: age.ago)
  end

  describe "activity" do
    it "ages out routine entries past their window" do
      old = entry(severity: "info", age: window_for("activity") + 1.day)
      kept = entry(severity: "info", age: window_for("activity") - 1.day)

      described_class.perform_now

      expect(ActivityEntry.exists?(old.id)).to be(false)
      expect(ActivityEntry.exists?(kept.id)).to be(true)
    end

    # "This source broke in March" is a question people actually ask, and an
    # error is the only row that can answer it.
    it "keeps errors long after routine entries are gone" do
      error = entry(severity: "error", age: window_for("activity") + 1.day)

      described_class.perform_now

      expect(ActivityEntry.exists?(error.id)).to be(true)
    end

    it "ages out errors too, eventually" do
      error = entry(severity: "error", age: window_for("activity errors") + 1.day)

      described_class.perform_now

      expect(ActivityEntry.exists?(error.id)).to be(false)
    end
  end

  describe "job runs" do
    it "ages out finished runs past their window" do
      old = JobRun.create!(job_key: "poll_sources", status: "succeeded",
        finished_at: (window_for("job runs") + 1.day).ago)

      described_class.perform_now

      expect(JobRun.exists?(old.id)).to be(false)
    end

    # A queued or running row is either live or orphaned, and ManagedJobs
    # decides which. Deleting one out from under a job loses track of it.
    it "never touches a run that has not finished, however old" do
      unfinished = JobRun.create!(job_key: "poll_sources", status: "running",
        created_at: 2.years.ago, started_at: 2.years.ago)

      described_class.perform_now

      expect(JobRun.exists?(unfinished.id)).to be(true)
    end
  end

  describe "transcode runs" do
    def run(failure:, age:, state: "exited")
      TranscodeRun.create!(state: state, failure: failure, started_at: age.ago, finished_at: state == "exited" ? age.ago : nil)
    end

    it "ages out runs that went fine after a fortnight, and failed ones after a season" do
      fine = run(failure: nil, age: window_for("transcode runs") + 1.day)
      failed = run(failure: "stalled", age: window_for("transcode runs") + 1.day)
      old_failure = run(failure: "crashed", age: window_for("failed transcode runs") + 1.day)
      remote_at_work = run(failure: nil, age: 1.year, state: "running")

      described_class.perform_now

      expect(TranscodeRun.exists?(fine.id)).to be(false)
      expect(TranscodeRun.exists?(failed.id)).to be(true)
      expect(TranscodeRun.exists?(old_failure.id)).to be(false)
      expect(TranscodeRun.exists?(remote_at_work.id)).to be(true)
    end
  end

  describe "notifications" do
    let(:user) do
      household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword")
    end

    it "ages out notifications the member has read" do
      old = Notification.create!(user: user, household: household, kind: "source_failing",
        title: "T", dedupe_key: "read-one", read_at: 1.day.ago,
        created_at: (window_for("read notifications") + 1.day).ago)

      described_class.perform_now

      expect(Notification.exists?(old.id)).to be(false)
    end

    # An unread notification has not done its job yet. Age is not consent.
    it "leaves an unread notification alone however old it is" do
      unread = Notification.create!(user: user, household: household, kind: "source_failing",
        title: "T", dedupe_key: "unread-one", created_at: 2.years.ago)

      described_class.perform_now

      expect(Notification.exists?(unread.id)).to be(true)
    end
  end

  describe "reporting" do
    it "says nothing when there was nothing to prune" do
      expect { described_class.perform_now }
        .not_to change { ActivityEntry.where(event: "prune.completed").count }
    end

    it "reports what it deleted, by kind" do
      entry(severity: "info", age: window_for("activity") + 1.day)

      described_class.perform_now

      record = ActivityEntry.find_by(event: "prune.completed")
      expect(record.payload["activity"]).to eq(1)
      expect(record.summary).to include("1 activity")
    end

    it "records a JobRun so the console can show it ran" do
      described_class.perform_now

      run = JobRun.find_by(job_key: described_class::JOB_KEY)
      expect(run.status).to eq("succeeded")
    end
  end

  # A year of backlog should drain in one run rather than one batch of it.
  it "keeps deleting past a single batch" do
    stub_const("#{described_class}::BATCH", 2)
    stale = 5.times.map { entry(severity: "info", age: window_for("activity") + 1.day) }

    described_class.perform_now

    expect(ActivityEntry.where(id: stale.map(&:id))).to be_empty
  end
end
