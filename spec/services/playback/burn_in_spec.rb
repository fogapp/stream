# typed: false
# frozen_string_literal: true

require "rails_helper"

# Picture subtitles burned in (PROPOSAL §6.2): nothing in a browser draws a
# DVD or DVB subtitle (nor a PGS one on an Apple TV), so choosing one
# converts the video with it drawn in. ffmpeg can't make picture subtitles
# from text, so this writes a PGS stream by hand — a white box on screen for
# three seconds (Matroska starts it at 0) — which takes the same overlay path
# as VobSub and DVB.
RSpec.describe "Burning in picture subtitles" do
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
  let(:chrome) { Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac]) }

  # One PGS segment: "PG", PTS, DTS (90 kHz), type, size, data.
  def segment(type, data, pts)
    [ "PG", [ pts, 0 ].pack("NN"), [ type, data.bytesize ].pack("Cn"), data ].join.b
  end

  # A display set showing a w×h white box at (x, y), and one clearing it.
  def pgs(width:, height:, box:, from:, to:)
    x, y, w, h = box
    pcs = ->(objects) { [ width, height, 0x10, 1, 0x80, 0, 0, objects ].pack("nnCnCCCC") + (objects.zero? ? "" : [ 1, 0, 0, x, y ].pack("nCCnn")) }
    wds = [ 1, 0, x, y, w, h ].pack("CCnnnn")
    pds = [ 0, 0, 1, 235, 128, 128, 255 ].pack("CCCCCCC")
    line = [ 0x00, 0xC0 | (w >> 8), w & 0xFF, 0x01, 0x00, 0x00 ].pack("C*")
    bitmap = [ w, h ].pack("nn") + (line * h)
    ods = [ 1, 0, 0xC0 ].pack("nCC") + [ bitmap.bytesize ].pack("N")[1..] + bitmap
    show = from * 90_000
    clear = to * 90_000
    segment(0x16, pcs.call(1), show) + segment(0x17, wds, show) + segment(0x14, pds, show) + segment(0x15, ods, show) +
      segment(0x80, "", show) + segment(0x16, pcs.call(0), clear) + segment(0x17, wds, clear) + segment(0x80, "", clear)
  end

  let(:source) do
    dir = build_root
    video = File.join(dir, "video.mp4")
    ToolRunner.run(%W[ffmpeg -v error -f lavfi -i color=c=black:s=640x360:r=24:d=6 -f lavfi -i sine=d=6 -c:v libx264 -preset ultrafast
      -g 24 -c:a aac -shortest #{video}], timeout: 60)
    subs = File.join(dir, "subs.sup")
    File.binwrite(subs, pgs(width: 640, height: 360, box: [ 220, 260, 200, 60 ], from: 1, to: 4))
    out = File.join(dir, "with-subs.mkv")
    result = ToolRunner.run(%W[ffmpeg -v error -i #{video} -i #{subs} -map 0 -map 1 -c copy #{out}], timeout: 60)
    raise result.stderr unless result.success?

    out
  end

  def session(burn:)
    library = create_library(household: household, roots: File.dirname(source))
    file = MediaFile.create!(household: household, library: library, path: source, size: File.size(source), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    file.reload
    subtitle = file.media_streams.find { |stream| stream.kind == "subtitle" }
    decision = Playback::Decision.new(file, chrome, burn_subtitle: burn ? subtitle.index : nil)
    movie = Movie.create!(household: household, library: library, title: "T")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file,
      method: decision.method.serialize, decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current)
  end

  # Mean brightness where the box goes, in the frame at a time.
  def brightness(path, at)
    crop = "crop=200:60:220:260,signalstats,metadata=print:key=lavfi.signalstats.YAVG"
    output = ToolRunner.run(%W[ffmpeg -v info -ss #{at} -i #{path} -frames:v 1 -vf #{crop} -f null -]).stderr
    output[/lavfi\.signalstats\.YAVG=([\d.]+)/, 1].to_f
  end

  it "converts the video with the subtitle drawn in, only while it's on screen" do
    stream = session(burn: true)
    expect(stream.method_enum).to eq(PlaybackSession::Method::VideoTranscode)
    expect(stream.decision["summary"]).to start_with("Subtitles drawn into the picture")

    web = Playback::Segments.new(stream)
    joined = File.join(@cache, "burned.mp4")
    File.open(joined, "wb") do |out|
      out.write(File.binread(web.init))
      web.plan.segments.each_index { |index| out.write(File.binread(web.segment(index))) }
    end
    expect(brightness(joined, 1.5)).to be > 150
    expect(brightness(joined, 4.5)).to be < 40
  end

  it "offers a DVD or DVB track as one to burn in, and doesn't touch the video otherwise" do
    expect(Subtitles::Tracks.format_for("dvd_subtitle")).to eq(Subtitles::Tracks::Format::Burn)
    expect(Subtitles::Tracks.format_for("dvb_subtitle")).to eq(Subtitles::Tracks::Format::Burn)
    expect(session(burn: false).method_enum).to eq(PlaybackSession::Method::Direct).or eq(PlaybackSession::Method::Remux)
  end
end
