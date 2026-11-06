# typed: false
# frozen_string_literal: true

require "rails_helper"

# What a run made is published under the GOP it really holds, once
# (PROPOSAL §6.3): read from the fragment itself, with real ffmpeg writing
# them the way a run does.
RSpec.describe Playback::Publisher do
  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    @made = Dir.mktmpdir("stream-made")
    @film = File.join(@made, "film.mkv")
    # B-frames, so a frame's decode time isn't its presentation time.
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=24000/1001:duration=12 -f lavfi
      -i sine=frequency=440:duration=12 -c:v libx264 -preset veryfast -bf 3 -g 300 -keyint_min 24 -sc_threshold 0
      -force_key_frames 2.5,5.2,9.0 -c:a aac #{@film}])
  end

  after { FileUtils.rm_rf([ @cache, @made ]) }

  let(:session_id) { SecureRandom.uuid }
  let(:keyframes) { Media::Keyframes::PacketScan.keyframes_ms(@film) }
  let(:plan) { Playback::SegmentPlan.new(gop_starts: keyframes, duration_ms: 12_000) }
  let(:publisher) { described_class.new(session_id: session_id, variant: 0, plan: plan) }

  # One run's output: every GOP from the start, numbered from `first`.
  def run(name, first: 0, extra: [])
    directory = Pathname.new(@made).join(name)
    FileUtils.mkdir_p(directory)
    ToolRunner.run(%W[ffmpeg -v error -y -i #{@film}] + extra + %W[-c:a copy -copyts -avoid_negative_ts disabled -f hls -hls_time 0.001 -hls_segment_type fmp4
      -hls_fmp4_init_filename init.mp4 -hls_segment_options movflags=+frag_discont -start_number #{first}
      -hls_segment_filename #{directory}/gop-%d.m4s -hls_list_size 0 #{directory}/run.m3u8])
    directory
  end

  it "reads where a fragment's picture starts from its own boxes" do
    expect(keyframes.size).to eq(4)
    made = run("copy", extra: %w[-c:v copy])
    tracks = Playback::Fragment.tracks(made.join("init.mp4"))
    expect(tracks.map(&:video)).to eq([ true, false ])
    starts = (0..3).map { |index| Playback::Fragment.video_span_ms(made.join("gop-#{index}.m4s"), tracks)&.first }
    starts.zip(keyframes).each { |start, keyframe| expect(start).to be_within(2).of(keyframe) }
    expect(Playback::Fragment.runs(made.join("gop-1.m4s")).map(&:samples)).to all(be_positive)
  end

  it "publishes each fragment under the GOP it holds, whatever its run called it, and its init once" do
    made = run("off-by-one", first: 1, extra: %w[-c:v copy])
    publisher.init(made.join("init.mp4"))
    expect((1..4).map { |number| publisher.fragment(made.join("gop-#{number}.m4s")) }).to eq([ 0, 1, 2, 3 ])
    expect(Playback::Cache.directory(session_id).children.map { |path| path.basename.to_s }.sort)
      .to eq(%w[gop-0.m4s gop-1.m4s gop-2.m4s gop-3.m4s init.mp4])
    expect(made.children.map { |path| path.basename.to_s }.grep(/gop-/)).to be_empty
    expect(Playback::Cache.init_ready?(session_id)).to be(true)
  end

  it "leaves a GOP already published as it is: its address never changes what it serves" do
    first = run("first", extra: %w[-c:v copy])
    publisher.init(first.join("init.mp4"))
    publisher.fragment(first.join("gop-2.m4s"))
    was = Playback::Cache.gop(session_id, 2).binread
    init = Playback::Cache.init(session_id).binread

    # Another run reaching the same GOP, with other bytes.
    second = run("second", extra: %w[-c:v copy -metadata title=other])
    File.open(second.join("gop-2.m4s"), "ab") { |file| file.write("free") }
    again = described_class.new(session_id: session_id, variant: 0, plan: plan)
    again.init(second.join("init.mp4"))
    # Nothing newly published, so nothing to announce.
    expect(again.fragment(second.join("gop-2.m4s"))).to be_nil
    expect(Playback::Cache.gop(session_id, 2).binread).to eq(was)
    expect(Playback::Cache.init(session_id).binread).to eq(init)
    expect(second.join("gop-2.m4s")).not_to exist
  end

  it "refuses a run whose file lacks a keyframe the plan has" do
    # Converted with keyframes of its own, a second off the plan's.
    made = run("elsewhere", extra: %w[-c:v libx264 -preset ultrafast -force_key_frames 3.5,6.2,10.0])
    publisher.init(made.join("init.mp4"))
    expect(publisher.fragment(made.join("gop-0.m4s"))).to eq(0)
    expect { publisher.fragment(made.join("gop-1.m4s")) }
      .to raise_error(described_class::Mismatch, /at 3\.5\d* s\) follows GOP 0, and the plan's GOP 1 \(2\.5\d* s\) isn't a keyframe/)
    expect(Playback::Cache.gop_ready?(session_id, 1)).to be(false)
    expect { described_class.new(session_id: session_id, variant: 0, plan: plan).fragment(made.join("gop-2.m4s")) }
      .to raise_error(described_class::Mismatch, /before its init/)
  end

  # A run carried on by another encoder
  # (a remote node gone) can't be played with the init already published.
  it "refuses a run whose picture is encoded differently from the init already published" do
    first = run("first", extra: %w[-c:v copy])
    publisher.init(first.join("init.mp4"))
    smaller = run("smaller", extra: %w[-c:v libx264 -preset veryfast -bf 3 -vf scale=160:90 -force_key_frames 2.5,5.2,9.0])
    expect { described_class.new(session_id: session_id, variant: 0, plan: plan).init(smaller.join("init.mp4")) }
      .to raise_error(described_class::Mismatch, /encoded differently|times its tracks differently/)

    # The same encode again is fine.
    same = run("same", extra: %w[-c:v copy])
    expect { described_class.new(session_id: session_id, variant: 0, plan: plan).init(same.join("init.mp4")) }.not_to raise_error
    expect(Playback::Fragment.tracks(same.join("init.mp4")).find(&:video)&.config).to start_with("avcC:")
  end

  it "takes an open GOP's keyframe that a run passing through stamped early as the GOP it is" do
    # Open GOPs: a keyframe shown after frames that follow it in decode
    # order, so it's held back longer than the film's first one.
    open = File.join(@made, "open.mkv")
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=24000/1001:duration=12 -c:v libx264 -preset veryfast
      -bf 3 -x264-params open_gop=1:keyint=72:min-keyint=72:scenecut=0 #{open}])
    keyframes = Media::Keyframes::PacketScan.keyframes_ms(open)
    open_plan = Playback::SegmentPlan.new(gop_starts: keyframes, duration_ms: 12_000)
    @film = open
    made = run("open", extra: %w[-c:v copy])
    tracks = Playback::Fragment.tracks(made.join("init.mp4"))
    starts = (0...keyframes.size).map { |index| Playback::Fragment.video_span_ms(made.join("gop-#{index}.m4s"), tracks)&.first }
    expect(starts.zip(keyframes).map { |start, keyframe| T.must(start) - keyframe }.min).to be < -Playback::SegmentPlan::ROUNDING_MS

    publisher = described_class.new(session_id: session_id, variant: 0, plan: open_plan)
    publisher.init(made.join("init.mp4"))
    expect((0...keyframes.size).map { |index| publisher.fragment(made.join("gop-#{index}.m4s")) }).to eq((0...keyframes.size).to_a)
  end

  # Frames a published GOP holds, played with its init: all of its stretch
  # of the film, nothing left out.
  def frames_in(gop)
    joined = Pathname.new(@made).join("joined-#{gop}.mp4")
    joined.binwrite(Playback::Cache.init(session_id).binread + Playback::Cache.gop(session_id, gop).binread)
    out = ToolRunner.run(%W[ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 #{joined}])
    out.stdout.strip.to_i
  end

  # Matroska Cues list as few as one
  # keyframe in three (seen on SNL, Love, Death & Robots, Man vs Baby), and
  # every keyframe left out used to stop the stream.
  it "makes a GOP of every fragment up to the next planned keyframe, when the index left keyframes out" do
    sparse = Playback::SegmentPlan.new(gop_starts: keyframes.values_at(0, 2), duration_ms: 12_000)
    made = run("sparse", extra: %w[-c:v copy])
    # One Publisher per fragment, as a remote run's uploads have.
    published = (0..3).map do |index|
      fresh = described_class.new(session_id: session_id, variant: 0, plan: sparse)
      fresh.init(made.join("init.mp4"))
      fresh.fragment(made.join("gop-#{index}.m4s"))
    end
    published << described_class.new(session_id: session_id, variant: 0, plan: sparse).tap { |p| p.init(made.join("init.mp4")) }.finish(made)

    expect(published.compact).to eq([ 0, 1 ])
    # GOP 0 is whole the moment its second fragment reaches GOP 1's keyframe.
    expect(published[1]).to eq(0)
    expect(Playback::Cache.directory(session_id).children.map { |path| path.basename.to_s }.sort).to eq(%w[gop-0.m4s gop-1.m4s init.mp4])
    fps = 24_000 / 1001.0
    expect(frames_in(0)).to be_within(1).of((keyframes[2] / 1000.0 * fps).round)
    expect(frames_in(1)).to be_within(2).of(((12_000 - keyframes[2]) / 1000.0 * fps).round)
  end

  it "skips the GOP a run began partway into, and makes the ones after it" do
    sparse = Playback::SegmentPlan.new(gop_starts: keyframes.values_at(0, 2), duration_ms: 12_000)
    made = run("partway", extra: %w[-c:v copy])
    publisher = described_class.new(session_id: session_id, variant: 0, plan: sparse)
    publisher.init(made.join("init.mp4"))
    # The run's first fragment is the film's second keyframe, 2.5 s into GOP 0.
    expect((1..3).map { |index| publisher.fragment(made.join("gop-#{index}.m4s")) }.compact + [ publisher.finish(made) ].compact).to eq([ 1 ])
    expect(Playback::Cache.gop_ready?(session_id, 0)).to be(false)
  end

  it "takes a run's first fragment a few frames past its GOP's keyframe as that GOP" do
    # Indexed 100 ms early: a seek for GOP 1 lands on the keyframe after it.
    early = Playback::SegmentPlan.new(gop_starts: [ 0, keyframes[1] - 100, keyframes[2], keyframes[3] ], duration_ms: 12_000)
    made = run("landing", extra: %w[-c:v copy])
    publisher = described_class.new(session_id: session_id, variant: 0, plan: early)
    publisher.init(made.join("init.mp4"))
    expect((1..3).map { |index| publisher.fragment(made.join("gop-#{index}.m4s")) }).to eq([ 1, 2, 3 ])
  end

  it "publishes the film's last GOP when its run ends, though its picture stops short of the container's end" do
    longer = Playback::SegmentPlan.new(gop_starts: keyframes, duration_ms: 14_000)
    made = run("tail", extra: %w[-c:v copy])
    publisher.init(made.join("init.mp4"))
    expect((0..3).map { |index| described_class.new(session_id: session_id, variant: 0, plan: longer).tap { |p| p.init(made.join("init.mp4")) }.fragment(made.join("gop-#{index}.m4s")) })
      .to eq([ 0, 1, 2, nil ])
    expect(described_class.new(session_id: session_id, variant: 0, plan: longer).tap { |p| p.init(made.join("init.mp4")) }.finish(made)).to eq(3)
  end

  it "keeps a keyframe the encoder added inside a grid slot as part of that slot" do
    grid = Playback::SegmentPlan.grid(12_000, 2_000)
    # The grid's keyframes, and one more at 3 s, inside the second slot.
    made = run("grid-extra", extra: %W[-c:v libx264 -preset ultrafast -force_key_frames 0,2,3,4,6,8,10])
    converted = described_class.new(session_id: session_id, variant: 0, plan: grid)
    converted.init(made.join("init.mp4"))
    published = (0..6).map { |number| converted.fragment(made.join("gop-#{number}.m4s")) } + [ converted.finish(made) ]
    expect(published.compact).to eq([ 0, 1, 2, 3, 4, 5 ])
    expect(frames_in(1)).to be_within(1).of((2 * 24_000 / 1001.0).round)
  end

  # The frame an input seek keeps for being on screen at the seek, just
  # before it, is where ffmpeg counts the run's time from: every keyframe it
  # forces is a little before its slot (an XviD AVI's by 4–10 ms, at 330 s
  # of Community). Taken as late in the slot before, it left its own slot
  # missing: "GOP 165 (330.0 s) isn't a keyframe of this file".
  it "starts a slot with a converted keyframe a frame before it" do
    grid = Playback::SegmentPlan.grid(12_000, 2_000)
    # The frame before each slot, at 24000/1001: 1.960 s, 3.962 s and so on.
    early = (1..5).map { |slot| format("%.3f", ((slot * 2 * 24_000 / 1001.0).floor * 1001 / 24_000.0)) }
    forced = %W[-c:v libx264 -preset ultrafast -force_key_frames #{([ '0' ] + early).join(',')}]
    made = run("grid-early", extra: forced)
    converted = described_class.new(session_id: session_id, variant: 0, plan: grid)
    converted.init(made.join("init.mp4"))
    published = (0..5).map { |number| converted.fragment(made.join("gop-#{number}.m4s")) } + [ converted.finish(made) ]
    expect(published.compact).to eq([ 0, 1, 2, 3, 4, 5 ])
    expect(frames_in(1)).to eq(48)

    # A run started for slot 3 begins on its early keyframe: slot 3, not the end of slot 2.
    again = run("grid-early-again", extra: forced)
    later = described_class.new(session_id: SecureRandom.uuid, variant: 0, plan: grid)
    later.init(again.join("init.mp4"))
    expect([ later.fragment(again.join("gop-3.m4s")), later.fragment(again.join("gop-4.m4s")) ]).to eq([ 3, 4 ])
  end

  it "puts a conversion's fragments on the grid, each in the slot its first frame is in" do
    grid = Playback::SegmentPlan.grid(12_000, 2_000)
    made = run("grid", first: 4, extra: %W[-c:v libx264 -preset ultrafast -force_key_frames #{Playback::FfmpegArgs.grid_keyframes(2.0)}])
    converted = described_class.new(session_id: session_id, variant: 0, plan: grid)
    converted.init(made.join("init.mp4"))
    expect((4..9).map { |number| converted.fragment(made.join("gop-#{number}.m4s")) }).to eq([ 0, 1, 2, 3, 4, 5 ])
  end
end
