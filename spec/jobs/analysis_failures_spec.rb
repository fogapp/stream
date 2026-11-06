# typed: false
# frozen_string_literal: true

require "rails_helper"

# CLAUDE.md invariant 5: never stamp success on failure. A file that probed
# fine and then went bad on disk (a half-copied replacement, a failing
# drive) makes each analysis step fail — and each says so on the file's
# AnalysisRun, where Needs attention finds it, and tries again later.
RSpec.describe "Analysis steps on a file that went bad" do
  let(:household) { Household.create!(name: "Bad") }
  let(:storage) { Dir.mktmpdir("stream-storage") }

  before do
    require_ffprobe!
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => storage))
  end

  after { FileUtils.rm_rf(storage) }

  let(:file) do
    root = build_root("Heat.mkv" => "h264_aac_ac3_subs.mkv")
    path = File.join(root, "Heat.mkv")
    media = MediaFile.create!(household: household, library: create_library(household: household, roots: root), path: path,
      size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(media).call
    File.write(path, "the rest of this file never arrived")
    settle_library_roots!
    media.reload
  end

  it "records a failed keyframes run with its error, and tries again" do
    expect(file.state).to eq("probed")

    IndexKeyframesJob.perform_now(file.id, true)

    analysis = file.analysis_runs.find_by(step: "keyframes")
    expect(analysis).to have_attributes(status: "failed", consecutive_failures: 1, finished_at: nil)
    expect(analysis.error).to be_present
    expect(IndexKeyframesJob).to have_been_enqueued.with(file.id, true)
  end

  # The one read serves every step: when it fails, each step says so.
  it "records a failed run for every step of the one read, with its error, and tries again" do
    expect(file.state).to eq("probed")

    AnalyzeMediaFileJob.perform_now(file.id)

    %w[trickplay loudness subtitles].each do |step|
      analysis = file.analysis_runs.find_by(step: step)
      expect(analysis).to have_attributes(status: "failed", consecutive_failures: 1, finished_at: nil), step
      expect(analysis.error).to be_present
    end
    expect(AnalyzeMediaFileJob).to have_been_enqueued.with(file.id)
  end
end
