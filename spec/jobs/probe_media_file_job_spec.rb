# typed: false
# frozen_string_literal: true

require "rails_helper"

# A library's first scan queues every file's whole-file analysis at once,
# months of it on the one heavy thread; what arrives afterwards mustn't wait
# behind all of that (Media::AnalysisPriority).
RSpec.describe ProbeMediaFileJob do
  let(:household) { Household.create!(name: "Stream") }

  def file_written(at)
    root = build_root("Heat/Heat.mkv" => "h264_aac_ac3_subs.mkv")
    library = create_library(household: household, roots: root)
    path = File.join(root, "Heat/Heat.mkv")
    MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: at, state: "discovered")
  end

  before { require_ffprobe! }

  it "queues a new file's analysis ahead of the back catalogue" do
    file = file_written(2.days.ago)
    expect { described_class.perform_now(file.id) }
      .to have_enqueued_job(AnalyzeMediaFileJob).with(file.id).at_priority(Media::AnalysisPriority::NEW)
  end

  # Each hourly scan queues again whatever's still waiting: only the first
  # of those has anything to do.
  it "leaves a file that's already been probed by the time it runs" do
    file = file_written(2.days.ago)
    described_class.perform_now(file.id)
    clear_enqueued_jobs
    allow(Media::FileProber).to receive(:new).and_call_original

    described_class.perform_now(file.id)

    expect(Media::FileProber).not_to have_received(:new)
    expect(enqueued_jobs).to be_empty
  end

  it "queues what follows even if reading the chapters fails, which the retry won't reach" do
    file = file_written(2.days.ago)
    allow(Markers::Detector).to receive(:from_chapters).and_raise(ActiveRecord::StatementInvalid, "boom")

    described_class.perform_now(file.id)

    expect(enqueued_jobs.map { |job| job["job_class"] }).to include("MatchMediaFileJob", "AnalyzeMediaFileJob")
  end

  it "queues an old file's analysis behind what's new" do
    file = file_written(3.years.ago)
    expect { described_class.perform_now(file.id) }
      .to have_enqueued_job(AnalyzeMediaFileJob).with(file.id).at_priority(Media::AnalysisPriority::BACKLOG)
  end
end
