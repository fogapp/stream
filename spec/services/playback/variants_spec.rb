# typed: false
# frozen_string_literal: true

require "rails_helper"

# Adaptive bitrate for real (PROPOSAL §6.3): a repackaged 1080p stream
# offers 720p and 480p versions, converted only when asked for, and cut at
# exactly the original's segment boundaries so a player can switch between
# them mid-stream.
RSpec.describe Playback::Variants do
  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::Signal).to receive(:request) { |session_id, gop, variant = 0| supervisor.request(session_id, gop, variant) }
    @publishing = publish_runs { supervisor }
  end

  after do
    @publishing.kill
    supervisor.stop_all
    FileUtils.rm_rf(@cache)
  end

  let(:supervisor) { Playback::Supervisor.new(encoder: Playback::Encoders::Kind::Software, log: ->(_) { }) }
  let(:household) { Household.create!(name: "Stream") }
  # Chrome: H.264 and AAC, but no Matroska — so a remux.
  let(:chrome) { Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac]) }

  # Twelve seconds of 1080p H.264 in Matroska, a keyframe every two seconds.
  let(:source) do
    dir = build_root
    path = File.join(dir, "tall.mkv")
    ToolRunner.run(%W[ffmpeg -v error -f lavfi -i testsrc2=size=1920x1080:rate=24:duration=12 -f lavfi -i sine=frequency=440:duration=12
      -c:v libx264 -preset ultrafast -g 48 -keyint_min 48 -sc_threshold 0 -c:a aac -shortest #{path}], timeout: 120)
    path
  end

  def session
    library = create_library(household: household, roots: File.dirname(source))
    file = MediaFile.create!(household: household, library: library, path: source, size: File.size(source), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    file.reload
    times, kind = Media::KeyframeIndex.from_container(file)
    Media::KeyframeIndex.store(file, times || Media::Keyframes::PacketScan.keyframes_ms(file.path),
      kind || Media::KeyframeIndex::Source::Packets)
    decision = Playback::Decision.new(file, chrome)
    movie = Movie.create!(household: household, library: library, title: "T")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file.reload,
      method: decision.method.serialize, decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current, adaptive: true)
  end

  def durations(playlist) = playlist.scan(/#EXTINF:([\d.]+),/).flatten.map(&:to_f)

  def first_pts(path)
    JSON.parse(ToolRunner.run(%W[ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -read_intervals %+#1 -of json #{path}]).stdout)
      .dig("packets", 0, "pts_time").to_f
  end

  it "offers only the original to a stream that isn't adaptive: one playlist, nothing smaller to drop to" do
    stream = session
    stream.update!(adaptive: false)
    expect(described_class.for(stream).map(&:index)).to eq([ 0 ])
    expect(Playback::Segments.master(stream)).to be_nil
  end

  # The transcoder asks for a version by index on every request: the
  # original is known without reading the file to build the ladder.
  it "finds the original without a query, and the same original the ladder starts with" do
    stream = session
    found = nil
    expect(count_queries { found = described_class.find(stream, 0) }).to be_empty
    expect(found).to have_attributes(index: 0, height: nil, original?: true)
    expect(described_class.for(stream).first).to have_attributes(index: 0, height: nil)
    expect(described_class.find(stream, 1)).to have_attributes(index: 1, height: 720)
    expect(described_class.find(stream, 9)).to be_nil
  end

  it "lists the original first, then smaller versions, in a master playlist" do
    stream = session
    expect(stream.method_enum).to eq(PlaybackSession::Method::Remux)

    master = Playback::Segments.master(stream)
    entries = master.lines.select { |line| line.start_with?("v") }.map(&:strip)
    expect(entries).to eq(%w[v0/index.m3u8 v1/index.m3u8 v2/index.m3u8])
    expect(master).to include("RESOLUTION=1920x1080", "RESOLUTION=1280x720", "RESOLUTION=854x480", 'CODECS="avc1.640028,mp4a.40.2"')
    expect(described_class.for(stream).map(&:height)).to eq([ nil, 720, 480 ])
  end

  it "converts a smaller version only when asked, with segments that line up with the original's" do
    stream = session
    original = Playback::Segments.new(stream, 0)
    smaller = Playback::Segments.new(stream, 2)
    expect(durations(smaller.playlist)).to eq(durations(original.playlist))

    File.binwrite(File.join(@cache, "orig-init.mp4"), File.binread(original.init))
    expect(Dir.exist?(Playback::Cache.directory(stream.id, 2))).to be(false)

    segments = original.plan.segments.each_index.to_a
    joined = File.join(@cache, "small.mp4")
    File.open(joined, "wb") do |out|
      out.write(File.binread(smaller.init))
      segments.each { |index| out.write(File.binread(smaller.segment(index))) }
    end
    probe = JSON.parse(ToolRunner.run(%W[ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height -of json #{joined}]).stdout)
    expect(probe["streams"].sole).to include("codec_name" => "h264", "height" => 480)
    expect(ToolRunner.run(%W[ffmpeg -v error -i #{joined} -f null -]).stderr).to eq("")

    # Each of its segments starts where the original's does.
    segments.each do |index|
      path = smaller.segment(index)
      with_init = File.join(@cache, "check-#{index}.mp4")
      File.binwrite(with_init, File.binread(Playback::Cache.init(stream.id, 2)) + File.binread(path))
      expect(first_pts(with_init)).to be_within(0.05).of(original.plan.segments[index].start_ms / 1000.0), "segment #{index}"
    end
  end

  it "offers no smaller versions for a stream that's already converting, or a small file" do
    stream = session
    stream.update!(decision: stream.decision.merge("video" => stream.decision["video"].merge("copy" => false)))
    expect(described_class.for(stream).size).to eq(1)
    expect(Playback::Segments.master(stream)).to be_nil
  end
end
