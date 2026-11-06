# typed: false
# frozen_string_literal: true

require "rails_helper"

# Media invariant 8 (CLAUDE.md): fan-out jobs only fan out, so every job that
# does the work carries a real limits_concurrency key. A new job fails here
# until it has one — or, if all it does is enqueue others, until it's added
# to FAN_OUT.
RSpec.describe "Job concurrency" do
  FAN_OUT = [ CaptureLiveStillsJob, DetectLibraryChangesJob, FetchTrailersJob, FollowGamesJob, IdentifyVideosJob, ImmichSyncsJob, PollChannelsJob, PrepareAiringsJob,
              RefreshSponsorSegmentsJob, ScheduleStationsJob ].freeze

  # Every job in app/jobs — not the ones other specs define for themselves.
  def jobs
    Rails.application.eager_load!
    ApplicationJob.descendants.select { |job| Object.const_source_location(job.name.to_s)&.first.to_s.start_with?(Rails.root.join("app/jobs").to_s) }
  end

  it "gives every job that does the work a concurrency key" do
    unkeyed = jobs.select { |job| job.concurrency_key.nil? }

    expect(unkeyed).to match_array(FAN_OUT)
  end

  # A semaphore isn't renewed while its job runs, and it's taken at dispatch:
  # one left at Solid Queue's three minutes lets a duplicate start beside a
  # read that's still going.
  it "holds a long job's concurrency slot for as long as the job can run" do
    long = jobs.select { |job| %w[heavy youtube].include?(job.queue_name.to_s) } + [ EmbedTitlesJob, IndexKeyframesJob, PollChannelJob ]
    default = SolidQueue.default_concurrency_control_period

    expect(long.select { |job| job.concurrency_duration <= default }).to be_empty
  end

  it "keeps the fan-out jobs to enqueueing" do
    household = Household.create!(name: "Fan")
    Station.create!(household: household, number: "4", name: "Four")

    FAN_OUT.each(&:perform_now)

    expect(WebMock).not_to have_requested(:any, //)
    expect(enqueued_jobs.map { |job| job["job_class"] }.uniq).to eq([ "ScheduleStationJob" ])
  end
end
