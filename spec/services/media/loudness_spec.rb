# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Media::Loudness do
  before { require_ffprobe! }

  let(:household) { Household.create!(name: "Loud") }

  def file_with(volume)
    root = build_root
    path = File.join(root, "tone.mkv")
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i sine=frequency=440:duration=6 -af volume=#{volume} -c:a aac #{path}])
    record = MediaFile.create!(household: household, library: create_library(household: household, roots: root), path: path,
      size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(record).call
    record.reload
  end

  it "measures integrated loudness and true peak, louder files reading louder" do
    quiet = file_with("0.1")
    loud = file_with("0.8")
    [ quiet, loud ].each { |file| AnalyzeMediaFileJob.perform_now(file.id) }

    expect(quiet.reload.loudness_lufs).to be < loud.reload.loudness_lufs - 15
    expect(loud.true_peak_dbfs).to be_between(-25, 0) # sine is -18 dBFS at full volume
    expect(loud.analysis_runs.find_by(step: "loudness").status).to eq("succeeded")
  end
end
