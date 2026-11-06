# typed: false
# frozen_string_literal: true

require "rails_helper"

# Solid Queue has no catch-all: a job sent to a queue no worker in
# config/queue.yml lists is accepted and never runs (the hourly clean-up of
# finished jobs sat in `solid_queue_recurring` for days).
RSpec.describe "Queue configuration" do
  let(:claimed) do
    config = YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true)
    config.fetch("production").fetch("workers").flat_map { |worker| worker.fetch("queues") }
  end

  it "has a worker for every recurring task's queue" do
    Rails.application.eager_load!
    jobs = ApplicationJob.descendants.index_by(&:name)
    tasks = YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true).fetch("production")
    queues = tasks.transform_values do |task|
      # A command runs as SolidQueue::RecurringJob, whose own queue nothing claims.
      task["queue"] || (jobs[task["class"]] || SolidQueue::RecurringJob).new.queue_name
    end

    expect(queues.reject { |_, queue| claimed.include?(queue) }).to eq({})
  end

  # The hold on the heavy queue is what keeps a whole-file read off the share
  # during a film (2026-10-08). It can't wait behind a Plex import.
  it "keeps the jobs that keep things in hand off the queues that long jobs use" do
    tasks = YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true).fetch("production")
    control = [ HoldHeavyWhileWatchingJob, FollowGamesJob, TraktScrobbleSweepJob, ReclaimOrphanedSemaphoresJob ]

    expect(control.map { |job| job.new.queue_name }.uniq).to eq([ "control" ])
    expect(tasks.values.select { |task| control.map(&:name).include?(task["class"]) }.map { |task| task["queue"] }.uniq).to eq([ "control" ])
    expect(Rails.application.config_for(:queue).fetch(:workers).select { |worker| worker[:queues].include?("control") }.sole)
      .to include(queues: [ "control" ], threads: 1)
  end

  it "gives integrations that can run for hours a queue of their own" do
    long = [ PlexImportJob, ImmichSyncJob, TraktPullJob, PollChannelJob, FetchTrailerJob, CheckTrailerJob ]

    expect(long.map { |job| job.new.queue_name }.uniq).to eq([ "sync" ])
    expect(claimed).to include("sync")
  end

  it "has a worker for every job's queue" do
    Rails.application.eager_load!
    queues = ApplicationJob.descendants.to_h { |job| [ job.name, job.new.queue_name ] }

    expect(queues.reject { |_, queue| claimed.include?(queue) }).to eq({})
  end
end
