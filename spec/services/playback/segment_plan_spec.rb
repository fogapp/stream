# typed: false
# frozen_string_literal: true

require "rails_helper"

# docs/PERF_PROPOSAL.md › P10: new sessions aim for 2 s segments, so the
# first frame and a seek wait on two seconds of film rather than six.
RSpec.describe Playback::SegmentPlan do
  it "cuts copied video at the first keyframe past each target" do
    plan = described_class.new(gop_starts: [ 0, 500, 1000, 1500, 2000, 2500, 5000, 5500, 6000 ], duration_ms: 7000, target_ms: 2000)
    expect(plan.segments.map { |segment| [ segment.first_gop, segment.last_gop ] }).to eq([ [ 0, 3 ], [ 4, 5 ], [ 6, 7 ], [ 8, 8 ] ])
    expect(plan.target_duration_seconds).to eq(3)

    six = described_class.new(gop_starts: [ 0, 500, 1000, 1500, 2000, 2500, 5000, 5500, 6000 ], duration_ms: 7000, target_ms: 6000)
    expect(six.segments.size).to eq(2)
  end

  it "puts converted video on a grid of the target, one GOP a segment" do
    plan = described_class.grid(9_500, 2000)
    expect(plan.gop_starts).to eq([ 0, 2000, 4000, 6000, 8000 ])
    expect(plan.segments.map(&:duration_ms)).to eq([ 2000, 2000, 2000, 2000, 1500 ])
  end

  it "finds the GOP a moment starts, and one stamped early only when asked and only nearer it than the one before" do
    plan = described_class.new(gop_starts: [ 1_107_773, 1_117_783, 1_191_023, 1_191_300 ], duration_ms: 1_200_000)
    expect(plan.gop_starting_at(1_117_784, 50)).to eq(1)
    expect(plan.gop_starting_at(1_117_781, 50)).to eq(1)
    expect(plan.gop_starting_at(1_190_856, 50)).to be_nil
    expect(plan.gop_starting_at(1_190_856, 50, early_ms: 750)).to eq(2)
    expect(plan.gop_starting_at(1_190_200, 50, early_ms: 750)).to be_nil
    expect(plan.gop_starting_at(1_191_100, 50, early_ms: 750)).to be_nil
    expect(plan.gop_starting_at(1_191_250, 50, early_ms: 750)).to eq(3)
    expect(plan.gop_starting_at(1_107_500, 50, early_ms: 750)).to eq(0)
  end

  it "forces a converted run's keyframes on its session's grid" do
    household = Household.create!(name: "Plan")
    library = create_library(household: household, roots: build_root)
    file = MediaFile.create!(household: household, library: library, path: File.join(library.roots.first, "x.ts"), size: 1, mtime: Time.current,
      state: "probed", duration_seconds: 60)
    session = PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: Movie.create!(household: household,
      library: library, title: "X"), media_file: file, method: "video_transcode", started_at: Time.current, last_seen_at: Time.current,
      segment_target_ms: 2000, decision: { "video" => { "index" => 0, "copy" => false, "codec" => "h264", "height" => 720 } })
    plan = described_class.for(session)
    expect(plan.segments.size).to eq(30)
    args = Playback::FfmpegArgs.build(session, plan, start_gop: 5, directory: Pathname.new("/tmp/x"),
      profile: Playback::Encoders::Profile.new(kind: Playback::Encoders::Kind::Software, tonemap_filter: nil))
    expect(args[args.index("-force_key_frames") + 1])
      .to eq("expr:if(isnan(prev_forced_t),1,gt(floor((t+0.0005)/2.000),floor((prev_forced_t+0.0005)/2.000)))")
  end
end
