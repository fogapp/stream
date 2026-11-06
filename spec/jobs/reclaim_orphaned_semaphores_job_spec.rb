# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReclaimOrphanedSemaphoresJob do
  # The queue tables live in a separate database in production and aren't part
  # of the test schema. Postgres DDL is transactional, so creating minimal
  # versions inside the example transaction leaves no trace behind.
  before do
    Rails.application.eager_load! # production's are all loaded
    conn = ActiveRecord::Base.connection
    conn.create_table :solid_queue_semaphores do |t|
      t.string :key, null: false
      t.integer :value, default: 1, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    conn.create_table :solid_queue_jobs do |t|
      t.string :queue_name, null: false
      t.string :class_name, null: false
      t.text :arguments
      t.integer :priority, default: 0, null: false
      t.string :active_job_id
      t.datetime :scheduled_at
      t.datetime :finished_at
      t.string :concurrency_key
      t.timestamps
    end
    conn.create_table :solid_queue_failed_executions do |t|
      t.bigint :job_id, null: false
      t.text :error
      t.datetime :created_at, null: false
    end
  end

  it "reads each job's own limit, so any job with a wider one is judged by it" do
    held = semaphore("HydrateVideoJob/youtube_details", value: 1) # one of two permits out
    idle = semaphore("HydrateVideoJob/idle", value: 2)

    described_class.perform_now

    expect(SolidQueue::Semaphore.where(id: [ held.id, idle.id ]).pluck(:id)).to eq([ idle.id ])
  end

  def semaphore(key, value: 0)
    SolidQueue::Semaphore.create!(key: key, value: value, expires_at: 48.hours.from_now)
  end

  # insert! rather than create!: the model's creation callbacks reach into
  # dispatch tables this spec doesn't build.
  def queue_job(key:, finished_at: nil)
    now = Time.current
    result = SolidQueue::Job.insert!(
      { queue_name: "archive", class_name: "ArchiveItemJob", concurrency_key: key,
        finished_at: finished_at, created_at: now, updated_at: now },
      returning: %w[id]
    )
    result.rows.fetch(0).fetch(0)
  end

  it "releases a semaphore whose job died without finishing" do
    semaphore("relocate_media")

    expect { described_class.perform_now }
      .to change(SolidQueue::Semaphore, :count).from(1).to(0)
    expect(ActivityEntry.unscoped.find_by(event: "semaphores.reclaimed")).to be_present
  end

  it "leaves a semaphore alone while its job is still live" do
    semaphore("item-123")
    queue_job(key: "item-123")

    expect { described_class.perform_now }.not_to change(SolidQueue::Semaphore, :count)
    expect(ActivityEntry.unscoped.find_by(event: "semaphores.reclaimed")).to be_nil
  end

  it "treats a finished job as a non-holder" do
    semaphore("item-123")
    queue_job(key: "item-123", finished_at: 1.minute.ago)

    expect { described_class.perform_now }
      .to change(SolidQueue::Semaphore, :count).from(1).to(0)
  end

  # A job in failed_executions is waiting for a human decision, not running;
  # holding its semaphore would block the re-enqueue that is the whole point.
  it "treats a failed job as a non-holder" do
    semaphore("item-123")
    job_id = queue_job(key: "item-123")
    SolidQueue::FailedExecution.insert!(
      { job_id: job_id, error: "boom", created_at: Time.current }
    )

    expect { described_class.perform_now }
      .to change(SolidQueue::Semaphore, :count).from(1).to(0)
  end

  # Solid Queue leaves a semaphore row behind after a normal finish, with its
  # permit handed back, until the row expires. That is health, not a crash.
  it "leaves a released semaphore alone and says nothing" do
    semaphore("ArchiveItemJob/item-123", value: 1)

    expect { described_class.perform_now }.not_to change(SolidQueue::Semaphore, :count)
    expect(ActivityEntry.unscoped.find_by(event: "semaphores.reclaimed")).to be_nil
  end

  context "with a job that allows two at once" do
    it "releases a semaphore still missing a permit" do
      semaphore("DownloadVideoJob/youtube_download", value: 1)

      expect { described_class.perform_now }
        .to change(SolidQueue::Semaphore, :count).from(1).to(0)
    end

    it "leaves one with both permits back alone" do
      semaphore("DownloadVideoJob/youtube_download", value: 2)

      expect { described_class.perform_now }.not_to change(SolidQueue::Semaphore, :count)
    end
  end
end
