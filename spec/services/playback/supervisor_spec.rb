# typed: false
# frozen_string_literal: true

require "rails_helper"

# The streaming pipeline with real ffmpeg (PROPOSAL §6.3): the supervisor
# starts and restarts runs, web joins the GOP fragments into segments, and
# ffprobe checks that what a player would receive decodes, with the right
# codecs and no gap where one run's fragments meet the next's.
RSpec.describe Playback::Supervisor do
  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::Signal).to receive(:request) { |session_id, gop| supervisor.request(session_id, gop) }
    @publishing = publish_runs { supervisor }
  end

  after do
    @publishing.kill
    supervisor.stop_all
    FileUtils.rm_rf(@cache)
  end

  let(:supervisor) { described_class.new(encoder: Playback::Encoders::Kind::Software, log: ->(_) { }) }
  let(:household) { Household.create!(name: "Stream") }

  CAPS = Playback::Capabilities.from_json(
    "hls" => "mse", "containers" => %w[mp4 webm], "video" => %w[h264 vp9 av1], "audio" => %w[aac opus], "max_audio_channels" => 2
  )

  def session_for(path)
    library = create_library(household: household, roots: File.dirname(path))
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(file).call
    file.reload
    times, source = Media::KeyframeIndex.from_container(file)
    Media::KeyframeIndex.store(file, times || Media::Keyframes::PacketScan.keyframes_ms(path),
      source || Media::KeyframeIndex::Source::Packets)
    decision = Playback::Decision.new(file, CAPS)
    movie = Movie.create!(household: household, library: library, title: "T")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie, media_file: file,
      method: decision.method.serialize, decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current)
  end

  # Every run throttled as a conversion is, so a short film is still being
  # made when the next request arrives.
  def keep_throttled
    allow(Playback::Pace).to receive(:for).and_wrap_original { |original, session, **| original.call(session, converting: true) }
  end

  # The same session converting its video instead of copying it: a run
  # that's throttled (Playback::Pace).
  def converting(session)
    session.update!(method: "video_transcode", decision: session.decision.merge("video" => session.decision["video"].merge("copy" => false)))
    session
  end

  def copy_fixture(name)
    dir = build_root
    FileUtils.cp(media_fixture(name), File.join(dir, name))
    File.join(dir, name)
  end

  # What the player would get for segments first..last, as one file.
  def stream_file(session, segments)
    web = Playback::Segments.new(session)
    out = File.join(@cache, "joined-#{SecureRandom.hex(3)}.mp4")
    File.open(out, "wb") do |file|
      file.write(File.binread(web.init))
      segments.each { |index| file.write(File.binread(web.segment(index))) }
    end
    out
  end

  def probe_streams(path)
    JSON.parse(ToolRunner.run(%W[ffprobe -v error -show_entries stream=codec_type,codec_name,channels,color_transfer
      -of json #{path}]).stdout).fetch("streams")
  end

  def first_pts(session, gop, stream)
    probe = File.join(@cache, "gop-#{gop}-#{SecureRandom.hex(2)}.mp4")
    File.binwrite(probe, File.binread(Playback::Cache.init(session.id)) + File.binread(Playback::Cache.gop(session.id, gop)))
    out = ToolRunner.run(%W[ffprobe -v error -select_streams #{stream} -show_entries packet=pts_time -of csv=p=0 #{probe}]).stdout
    out.lines.map(&:to_f).min
  end

  def first_video_pts(session, gop) = first_pts(session, gop, "v:0")

  # Every frame of every stream decodes, with nothing on stderr.
  def decodes_cleanly(path)
    result = ToolRunner.run(%W[ffprobe -v error -count_frames -show_entries stream=codec_type,nb_read_frames -of json #{path}])
    expect(result.stderr).to eq(""), result.stderr
    frames = JSON.parse(result.stdout).fetch("streams").map { |stream| stream["nb_read_frames"].to_i }
    expect(frames).to all(be_positive)
  end

  it "remuxes an MKV into segments that decode, copying video and audio untouched" do
    session = session_for(copy_fixture("h264_aac_ac3_subs.mkv"))
    expect(session.method).to eq("remux")

    web = Playback::Segments.new(session)
    joined = stream_file(session, (0...web.plan.segments.size).to_a)

    expect(probe_streams(joined).map { |s| [ s["codec_type"], s["codec_name"] ] }).to eq([ %w[video h264], %w[audio aac] ])
    decodes_cleanly(joined)
    expect(web.playlist).to include("#EXT-X-MAP:URI=\"init.mp4\"", "seg-0.m4s", "#EXT-X-ENDLIST")
  end

  it "converts DTS 5.1 to AAC stereo and leaves the video alone" do
    session = session_for(copy_fixture("h264_dts.mkv"))
    expect(session.method).to eq("audio_transcode")

    joined = stream_file(session, [ 0 ])
    audio = probe_streams(joined).find { |s| s["codec_type"] == "audio" }
    expect(audio).to include("codec_name" => "aac", "channels" => 2)
    decodes_cleanly(joined)
  end

  it "tone-maps 10-bit HEVC HDR10 to 8-bit H.264 for a browser without HEVC" do
    session = session_for(copy_fixture("hevc_main10_hdr10.mkv"))
    expect(session.method).to eq("video_transcode")
    expect(session.decision.dig("video", "tonemap")).to be(true)

    joined = stream_file(session, [ 0 ])
    video = probe_streams(joined).find { |s| s["codec_type"] == "video" }
    expect(video["codec_name"]).to eq("h264")
    expect(video["color_transfer"]).not_to eq("smpte2084")
    decodes_cleanly(joined)
  end

  describe "seeking" do
    # 60 s with a keyframe every 2 s: thirty GOPs, ten 6 s segments. A short
    # throttle burst, so a run is still going when the seek arrives — even
    # one that only repackages, which isn't throttled for real (Pace, R2).
    before do
      stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache, "STREAM_READRATE_BURST" => "4"))
      keep_throttled
    end

    let(:long) do
      path = File.join(build_root, "long.mkv")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=24:duration=60 -f lavfi
        -i sine=frequency=440:duration=60 -c:v libx264 -preset ultrafast -g 48 -keyint_min 48 -c:a aac #{path}])
      path
    end

    it "restarts ffmpeg for a far seek and back, and fragments from different runs join without a gap" do
      session = session_for(long)
      plan = Playback::Segments.new(session).plan
      expect(plan.segments.size).to eq(10)

      stream_file(session, [ 0 ])
      first_run = supervisor.runs.fetch(session.id).handle.pid

      supervisor.request(session.id, 20)
      expect(supervisor.runs.fetch(session.id)).to have_attributes(start_gop: 20)
      expect(supervisor.runs.fetch(session.id).handle.pid).not_to eq(first_run)

      # Back into the gap the first run never reached: a third run fills it,
      # and its fragments meet the first run's.
      joined = stream_file(session, [ 0, 1, 2, 3 ])
      expect(supervisor.runs.fetch(session.id).start_gop).to be < 20

      # Whichever run wrote it, each GOP fragment starts at its planned
      # keyframe — a restarted run that seeks one keyframe early names
      # every fragment one GOP off.
      (0..11).each do |gop|
        expect(first_video_pts(session, gop)).to be_within(0.05).of(plan.gop_start_ms(gop) / 1000.0), "GOP #{gop}"
      end
      decodes_cleanly(joined)
      duration = JSON.parse(ToolRunner.run(%W[ffprobe -v error -show_entries format=duration -of json #{joined}]).stdout)
      expect(duration.dig("format", "duration").to_f).to be_within(0.5).of(24.0)
    end

    # What a real film is: B-frames, keyframes wherever its scenes cut, and
    # Matroska's whole-millisecond timestamps. ffmpeg moves an input seek
    # back 3/23 s for a file like this, which a seek a hair past the
    # keyframe landed one keyframe early from: every fragment of the run
    # was named one GOP off, and its first had no sound at all.
    def film(audio)
      path = File.join(build_root, "film-#{audio.first}.mkv")
      keyframes = [ 5.0, 9.3, 16.0, 26.4, 28.9, 31.0, 35.8, 40.3, 42.4, 52.8, 54.0 ].join(",")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=24000/1001:duration=60 -f lavfi
        -i sine=frequency=440:duration=60 -c:v libx264 -preset veryfast -bf 3 -g 300 -keyint_min 24 -sc_threshold 0
        -force_key_frames #{keyframes}] + audio + [ path ])
      path
    end

    { "copied" => %w[-c:a aac], "converted" => %w[-c:a ac3 -b:a 192k] }.each do |how, audio|
      it "starts a run on the keyframe asked for in a film with B-frames, its sound whole (#{how} audio)" do
        session = session_for(film(audio))
        expect(session.method).to eq(how == "copied" ? "remux" : "audio_transcode")
        plan = Playback::Segments.new(session).plan
        expect(plan.gop_count).to eq(12)

        [ 7, 3, 10 ].each do |gop|
          supervisor.request(session.id, gop)
          expect(supervisor.runs.fetch(session.id)).to have_attributes(start_gop: gop)
          Timeout.timeout(20) { sleep 0.05 until Playback::Cache.gop_ready?(session.id, gop + 1) }
          (gop..gop + 1).each do |index|
            start = plan.gop_start_ms(index) / 1000.0
            expect(first_video_pts(session, index)).to be_within(0.005).of(start), "GOP #{index}"
            # Sound from where the picture starts: none of it cut off.
            expect(first_pts(session, index, "a:0")).to be <= start + 0.03, "GOP #{index}'s audio"
          end
        end
      end
    end

    # Matroska Cues that list only some
    # of a film's keyframes stopped every stream that met an unlisted one.
    it "streams a film whose index left keyframes out, seeks and all, whole and without a gap" do
      session = session_for(film(%w[-c:a aac]))
      file = session.media_file
      every = file.keyframes
      Media::KeyframeIndex.store(file, every.select.with_index { |_, index| index.even? }, Media::KeyframeIndex::Source::Cues)
      plan = Playback::Segments.new(session).plan
      expect(plan.gop_count).to eq((every.size + 1) / 2)

      # Into the middle first, then the whole film from the top.
      supervisor.request(session.id, plan.gop_count / 2)
      joined = stream_file(session, (0...plan.segments.size).to_a)

      expect(session.reload.transcode_error).to be_nil
      decodes_cleanly(joined)
      frames = ToolRunner.run(%W[ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 #{joined}])
      expect(frames.stdout.to_i).to be_within(2).of((60 * 24_000 / 1001.0).round)
      (0...plan.gop_count).each do |gop|
        expect(first_video_pts(session, gop)).to be_within(0.005).of(plan.gop_start_ms(gop) / 1000.0), "GOP #{gop}"
      end
    end

    # Silent failure is the enemy: a run that makes something other than
    # the plan's GOPs is stopped, nothing of it served, and the session says why.
    it "stops a run whose fragments aren't the plan's, and records why" do
      session = session_for(long)
      file = session.media_file
      Media::KeyframeIndex.store(file, file.keyframes.map { |time| time + 1000 }, Media::KeyframeIndex::Source::Packets)
      supervisor.request(session.id, 0)
      Timeout.timeout(20) do
        loop do
          supervisor.drain
          break if session.reload.transcode_error

          sleep 0.05
        end
      end
      expect(session.transcode_error).to match(/weren't what was planned: gop-0\.m4s \(at 0\.0 s\) is before the plan's first GOP/)
      expect(supervisor.runs).to be_empty
      expect(Playback::Cache.directory(session.id).children.map { |path| path.basename.to_s }).to contain_exactly("ffmpeg.log", "init.mp4")
      expect(ActivityEntry.where(event: "transcode.failed").count).to eq(1)
    end

    it "waits for a nearby GOP instead of restarting" do
      session = session_for(long)
      Playback::Segments.new(session).init
      pid = supervisor.runs.fetch(session.id).handle.pid
      supervisor.request(session.id, 2)
      expect(supervisor.runs.fetch(session.id).handle.pid).to eq(pid)
    end

    # The baseline's twenty-second seeks (docs/PERF_PROPOSAL.md §6): a
    # request the player abandoned kept asking again, and each time moved
    # ffmpeg back away from where the viewer had gone.
    # A conversion started anywhere but the top used to get the encoder's
    # own 10 s GOPs: its keyframe expression assumed a clock that ffmpeg
    # 9 (and jellyfin-ffmpeg 7, for some inputs) doesn't give it.
    it "cuts a conversion started mid-film on its session's 2 s grid" do
      session = session_for(long)
      session.update!(segment_target_ms: 2000, method: "video_transcode",
        decision: session.decision.merge("video" => session.decision["video"].merge("copy" => false, "codec" => "h264", "height" => 180)))
      plan = Playback::Segments.new(session).plan
      expect(plan.gop_count).to eq(30)
      supervisor.request(session.id, 12)
      Timeout.timeout(30) { sleep 0.05 until Playback::Cache.gop_ready?(session.id, 15) }
      (12..14).each do |gop|
        expect(first_video_pts(session, gop)).to be_within(0.05).of(gop * 2.0), "GOP #{gop}"
      end
    end

    it "never moves a run for a resend once the session has asked for somewhere else" do
      session = session_for(long)
      supervisor.request(session.id, 0)
      supervisor.request(session.id, 20)
      pid = supervisor.runs.fetch(session.id).handle.pid

      supervisor.request(session.id, 1, resent: true)
      expect(supervisor.runs.fetch(session.id)).to have_attributes(start_gop: 20)
      expect(supervisor.runs.fetch(session.id).handle.pid).to eq(pid)
    end

    it "honours a resend when nothing newer was asked (a transcoder that missed the first)" do
      session = session_for(long)
      supervisor.request(session.id, 12, resent: true)
      expect(supervisor.runs.fetch(session.id)).to have_attributes(start_gop: 12)
    end

    it "announces each fragment a run finishes, once" do
      announced = []
      allow(Playback::Signal).to receive(:ready) { |session_id, variant, gop| announced << [ session_id, variant, gop ] }
      session = session_for(long)
      supervisor.request(session.id, 0)
      Timeout.timeout(20) { sleep 0.05 until Playback::Cache.gop_ready?(session.id, 2) }
      supervisor.publish_ready
      first = announced.last
      expect(first[0..1]).to eq([ session.id, 0 ])
      expect(first[2]).to be >= 2
      supervisor.publish_ready
      expect(announced.last).to eq(first).or(satisfy { |latest| latest[2] > first[2] })
    end

    it "holds a restart a moment and starts only the last place asked for" do
      held = described_class.new(encoder: Playback::Encoders::Kind::Software, log: ->(_) { }, debounce: 0.05)
      session = session_for(long)
      held.request(session.id, 10)
      held.request(session.id, 20)
      held.drain
      expect(held.runs).to be_empty
      expect(held.next_due_in).to be_between(0, 0.05)

      sleep 0.06
      held.drain
      expect(held.runs.fetch(session.id)).to have_attributes(start_gop: 20)
    ensure
      held&.stop_all
    end

    # A film's GOPs can be ten seconds: the fragment after a run's first is
    # further than "the next ten seconds" and still the next thing it makes.
    it "waits for the GOPs just after a run's first, however long they are, before it has made anything" do
      session = session_for(film(%w[-c:a aac]))
      plan = Playback::Segments.new(session).plan
      # GOP 3 is ten seconds long; GOP 5 starts 12.9 s after it does.
      expect(plan.gop_start_ms(5) - plan.gop_start_ms(3)).to be > described_class::STARTING_REACH_MS
      supervisor.request(session.id, 3)
      pid = supervisor.runs.fetch(session.id).handle.pid
      supervisor.request(session.id, 5)
      expect(supervisor.runs.fetch(session.id).handle.pid).to eq(pid)
      supervisor.request(session.id, 9)
      expect(supervisor.runs.fetch(session.id).start_gop).to eq(9)
    end

    # A run still inside its burst is going at disk speed, and won't be
    # past it: a seek far beyond the burst isn't a moment away.
    it "restarts for a seek past the burst of a run that has only just begun" do
      session = session_for(long)
      supervisor.request(session.id, 0)
      pid = supervisor.runs.fetch(session.id).handle.pid
      Timeout.timeout(20) { sleep 0.01 until Playback::Cache.gop_ready?(session.id, 0) }
      sleep 0.25
      supervisor.request(session.id, 25)
      expect(supervisor.runs.fetch(session.id).handle.pid).not_to eq(pid)
      expect(supervisor.runs.fetch(session.id).start_gop).to eq(25)
    end

    it "restarts rather than wait on a throttled run that won't get there within a second" do
      session = session_for(long)
      supervisor.request(session.id, 0)
      pid = supervisor.runs.fetch(session.id).handle.pid
      # Past the 4 s burst: from here the run makes 2 s of film a second.
      Timeout.timeout(20) { sleep 0.05 until Playback::Cache.gop_ready?(session.id, 3) }
      sleep 0.3
      # Twelve seconds of film past the run's frontier is six seconds away.
      frontier = (0..29).find { |gop| !Playback::Cache.gop_ready?(session.id, gop) }
      supervisor.request(session.id, frontier + 6)
      expect(supervisor.runs.fetch(session.id).handle.pid).not_to eq(pid)
      expect(supervisor.runs.fetch(session.id).start_gop).to eq(frontier + 6)
    end
  end

  # Formats the arguments used to break.
  describe "files from elsewhere" do
    # A broadcast recording: MPEG-TS, ADTS AAC, timestamps that start at
    # 95,000 s, and no index of its own.
    let(:recording) do
      path = File.join(build_root, "recording.ts")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=25:duration=20 -f lavfi -i sine=frequency=440:duration=20
        -c:v libx264 -preset ultrafast -g 50 -c:a aac -output_ts_offset 95000 -f mpegts #{path}])
      path
    end

    # Seconds of picture: its frames, at the 25 fps these are made at.
    def duration_of(path)
      ToolRunner.run(%W[ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 #{path}])
        .stdout.to_i / 25.0
    end

    it "repackages a recording that starts 26 hours in, copying its ADTS AAC" do
      session = session_for(recording)
      expect(session.method).to eq("remux")
      expect(session.media_file.keyframes.first).to be > 95_000_000

      plan = Playback::Segments.new(session).plan
      joined = stream_file(session, (0...plan.segments.size).to_a)
      decodes_cleanly(joined)
      expect(probe_streams(joined).map { |stream| stream["codec_name"] }).to eq(%w[h264 aac])
      expect(duration_of(joined)).to be_within(0.5).of(20.0)
      expect(session.reload.transcode_error).to be_nil
    end

    it "converts a recording that starts 26 hours in on a grid that starts where it does" do
      stub_const("CAPS", Playback::Capabilities.from_json("hls" => "mse", "containers" => %w[mp4], "video" => %w[vp9],
        "audio" => %w[aac], "max_audio_channels" => 2))
      session = session_for(recording)
      expect(session.method).to eq("video_transcode")
      plan = Playback::Segments.new(session).plan
      expect(plan.gop_start_ms(0)).to be_within(100).of(95_001_400)
      # Ten seconds in, on the player's clock, is ten seconds past where the file starts.
      at = plan.segments.fetch(plan.segment_at(10_000))
      expect(at.start_ms).to be <= plan.gop_start_ms(0) + 10_000
      expect(at.start_ms + at.duration_ms).to be > plan.gop_start_ms(0) + 10_000

      # From the middle, as a resume would, then the whole of it.
      stream_file(session, [ plan.segment_at(10_000) ])
      joined = stream_file(session, (0...plan.segments.size).to_a)
      decodes_cleanly(joined)
      expect(duration_of(joined)).to be_within(0.6).of(20.0)
      expect(session.reload.transcode_error).to be_nil
    end

    it "deinterlaces interlaced 4:2:2 camcorder video into what a browser decodes" do
      path = File.join(build_root, "camcorder.mts")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=25:duration=6 -f lavfi -i sine=frequency=440:duration=6
        -c:v libx264 -preset ultrafast -flags +ildct+ilme -x264-params tff=1 -pix_fmt yuv422p -c:a aac -f mpegts #{path}])
      session = session_for(path)
      expect(session.method).to eq("video_transcode")
      expect(session.decision["video"]).to include("deinterlace" => true)

      plan = Playback::Segments.new(session).plan
      joined = stream_file(session, (0...plan.segments.size).to_a)
      decodes_cleanly(joined)
      picture = JSON.parse(ToolRunner.run(%W[ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt,field_order -of json #{joined}]).stdout)
        .dig("streams", 0)
      expect(picture["pix_fmt"]).to eq("yuv420p")
      expect(picture["field_order"].to_s).to be_in([ "", "progressive", "unknown" ])
    end

    it "strips Dolby Vision's RPU for a client without it, and tags profile 5 dvh1 for one with it" do
      profile = Playback::Encoders::Profile.new(kind: Playback::Encoders::Kind::Software, tonemap_filter: nil)
      expect(Playback::FfmpegArgs.video_args(Playback::FfmpegArgs::VideoPlan.from("copy" => true, "codec" => "hevc", "dv_strip" => true), 0.0, profile, 2.0))
        .to eq(%w[-c:v copy -bsf:v dovi_rpu=strip=1 -tag:v hvc1])
      expect(Playback::FfmpegArgs.video_args(Playback::FfmpegArgs::VideoPlan.from("copy" => true, "codec" => "hevc", "dv_tag" => "dvh1"), 0.0, profile, 2.0))
        .to eq(%w[-c:v copy -tag:v dvh1])
    end

    it "repackages H.264 in an AVI, whose packets carry no presentation time" do
      path = File.join(build_root, "home.avi")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=25:duration=12 -f lavfi -i sine=frequency=440:duration=12
        -c:v libx264 -preset ultrafast -g 50 -bf 0 -c:a aac #{path}])
      keyframes = Media::Keyframes::PacketScan.keyframes_ms(path, duration_seconds: 12.0)
      expect(keyframes.size).to eq(6)
      expect(keyframes.each_cons(2).map { |a, b| b - a }).to all(eq(2000))

      session = session_for(path)
      expect(session.method).to eq("remux")
      plan = Playback::Segments.new(session).plan
      joined = stream_file(session, (0...plan.segments.size).to_a)
      decodes_cleanly(joined)
      expect(duration_of(joined)).to be_within(0.5).of(12.0)
    end
  end

  # Every run is on the record, a stuck
  # or crashed one is started again once, and only then is the session told.
  describe "keeping runs honest" do
    before do
      stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache, "STREAM_READRATE_BURST" => "4"))
      keep_throttled
    end

    let(:long) do
      path = File.join(build_root, "long.mkv")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=24:duration=60 -f lavfi
        -i sine=frequency=440:duration=60 -c:v libx264 -preset ultrafast -g 48 -keyint_min 48 -c:a aac #{path}])
      path
    end

    def run_of(session) = supervisor.runs.fetch(session.id)

    def tick_until(timeout: 20)
      Timeout.timeout(timeout) do
        until yield
          supervisor.tick
          supervisor.drain
          sleep 0.05
        end
      end
    end

    it "writes a row for each run here: what it ran, and that a seek stopped it rather than it failing" do
      session = session_for(long)
      supervisor.request(session.id, 0)
      first = TranscodeRun.find_by!(playback_session: session)
      expect(first).to have_attributes(state: "running", transcode_node_id: nil, start_gop: 0, variant: 0, encoder: "software")
      expect(first.argv).to include("ffmpeg", "-loglevel", "warning")

      supervisor.request(session.id, 25)
      expect(first.reload).to have_attributes(state: "exited", failure: nil)
      expect(first.finished_at).to be_present
      expect(TranscodeRun.where(playback_session: session).order(:created_at).last).to have_attributes(start_gop: 25, state: "running")
    end

    it "starts a crashed run again where it was wanted, and gives up on the second crash" do
      session = session_for(long)
      supervisor.request(session.id, 12)
      crashed = run_of(session).handle.pid
      Process.kill("SEGV", T.must(crashed))
      tick_until { supervisor.runs[session.id] && run_of(session).handle.pid != crashed }

      record = TranscodeRun.where(playback_session: session).order(:created_at).first
      expect(record).to have_attributes(failure: "crashed", signal: Signal.list.fetch("SEGV"))
      expect(run_of(session).start_gop).to eq(12)
      expect(session.reload.transcode_error).to be_nil

      Process.kill("SEGV", T.must(run_of(session).handle.pid))
      tick_until { session.reload.transcode_error }
      expect(session.transcode_error).to start_with("ffmpeg was killed by SIGSEGV")
      expect(supervisor.runs).to be_empty
      expect(ActivityEntry.where(event: "transcode.failed").count).to eq(1)
    end

    it "kills a run that makes nothing while a GOP is wanted, and starts it again" do
      stub_const("#{described_class}::STALL_AFTER", 0.5)
      stub_const("#{described_class}::FIRST_OUTPUT_WITHIN", 0.5)
      session = session_for(long)
      supervisor.request(session.id, 20)
      stuck = T.must(run_of(session).handle.pid)
      # A read that never returns, as far as anyone can tell.
      Process.kill("STOP", stuck)
      supervisor.tick
      tick_until { supervisor.runs[session.id] && run_of(session).handle.pid != stuck }

      expect(TranscodeRun.where(playback_session: session).order(:created_at).first).to have_attributes(failure: "stalled")
      expect(run_of(session).start_gop).to eq(20)
      Timeout.timeout(20) { sleep 0.05 until Playback::Cache.gop_ready?(session.id, 20) }
      expect(session.reload.transcode_error).to be_nil
    ensure
      begin
        Process.kill("KILL", stuck) if stuck
      rescue Errno::ESRCH
        nil
      end
    end

    it "answers a request made while an old failure is still on the session, once the restart it asks for clears it" do
      session = session_for(long)
      session.update_columns(transcode_error: "ffmpeg exited 1: long ago") # rubocop:disable Rails/SkipsModelValidations
      # The transcoder hears a request a moment later, as it does for real.
      allow(Playback::Signal).to receive(:request) do |session_id, gop|
        Thread.new do
          sleep 0.3
          ActiveRecord::Base.connection_pool.with_connection { supervisor.request(session_id, gop) }
        end
      end
      joined = stream_file(session, [ 0 ])
      decodes_cleanly(joined)
      expect(session.reload.transcode_error).to be_nil
    end

    def process_state(pid) = `ps -o stat= -p #{pid}`.strip

    it "pauses a run far ahead of what the player asked for, and lets it go again when asked for more" do
      stub_const("#{described_class}::AHEAD_PAUSE_MS", 6_000)
      stub_const("#{described_class}::AHEAD_RESUME_MS", 3_000)
      session = session_for(long)
      supervisor.request(session.id, 0)
      pid = T.must(run_of(session).handle.pid)
      tick_until { run_of(session).paused }
      expect(process_state(pid)).to start_with("T")
      made = Dir[Playback::Cache.directory(session.id).join("gop-*.m4s").to_s].size

      # The player asks for further than it has made: going again.
      supervisor.request(session.id, run_of(session).frontier + 1)
      expect(run_of(session).paused).to be(false)
      expect(process_state(pid)).not_to start_with("T")
      Timeout.timeout(20) { sleep 0.05 until Dir[Playback::Cache.directory(session.id).join("gop-*.m4s").to_s].size > made }
    end

    describe "pacing for the share (docs/APPLETV_STALLS.md › R1)" do
      before do
        allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
        Playback::ShareSpeed.forget!
      end

      after { Playback::ShareSpeed.forget! }

      def root_of(session) = Playback::Pace.root_of(session.media_file)

      def readrate_args(session)
        argv = TranscodeRun.where(playback_session_id: session.id).order(:created_at).last.argv
        [ argv[argv.index("-readrate") + 1], argv[argv.index("-readrate_initial_burst") + 1] ]
      end

      it "reads a channel tuned ahead only enough to preroll, at real time" do
        session = session_for(long)
        session.update!(standby: true)
        supervisor.request(session.id, 0)
        expect(readrate_args(session)).to eq(%w[1.0 4.0])
      end

      it "learns how fast a share reads from a run's burst" do
        # A 4 s burst is over before it could be measured, and its floor
        # alone wouldn't prove the share fast: it's left unmeasured.
        stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache, "STREAM_READRATE_BURST" => "60"))
        session = session_for(long)
        supervisor.request(session.id, 0)
        tick_until { Playback::ShareSpeed.read(root_of(session)) }
        expect(Playback::ShareSpeed.read(root_of(session))).to be > Playback::Pace.bitrate_of(session.media_file) * 2
      end

      context "with a run on a remote transcoder" do
        def remote_run(session, gops:, seconds: 30.0)
          plan = Playback::SegmentPlan.for(session)
          allow(Playback::Cache).to receive(:gop_ready?) { |_id, gop, _variant| gop < gops }
          pace = Playback::Pace.new(rate: 2.0, burst: 10.0, root: root_of(session), bitrate: Playback::Pace.bitrate_of(session.media_file))
          Playback::Supervisor::Run.new(session_id: session.id, handle: Playback::Runner::RemoteHandle.new(run_id: SecureRandom.uuid), start_gop: 0,
            frontier: 0, clock: Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f - seconds, staging: Pathname.new(@cache), plan: plan, pace: pace)
        end

        def film_in(session, gops) = Playback::SegmentPlan.for(session).gop_start_ms(gops) / 1000.0

        it "raises a reading the share has beaten" do
          session = session_for(long)
          bitrate = Playback::Pace.bitrate_of(session.media_file)
          Playback::ShareSpeed.record(root_of(session), 1.0)
          Playback::ShareMeasure.call(remote_run(session, gops: 5))
          expect(Playback::ShareSpeed.read(root_of(session))).to be_within(1).of(film_in(session, 5) * bitrate / 30.0)
        end

        it "leaves a reading alone when the run was no faster, however slow its machine" do
          session = session_for(long)
          known = Playback::Pace.bitrate_of(session.media_file) * 100
          Playback::ShareSpeed.record(root_of(session), known)
          Playback::ShareMeasure.call(remote_run(session, gops: 5))
          expect(Playback::ShareSpeed.read(root_of(session))).to eq(known)
        end

        it "waits out a remote run's slower start" do
          session = session_for(long)
          run = remote_run(session, gops: 5, seconds: 5.0)
          Playback::ShareMeasure.call(run)
          expect(run.measured).to be(false)
          expect(Playback::ShareSpeed.read(root_of(session))).to be_nil
        end

        it "ignores a run that ran into GOPs already made" do
          session = session_for(long)
          gops = Playback::SegmentPlan.for(session).gop_count
          Playback::ShareMeasure.call(remote_run(session, gops: gops, seconds: 21.0))
          expect(Playback::ShareSpeed.read(root_of(session))).to be_nil
        end
      end

      it "gives a conversion from a slow share a shorter burst" do
        stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache, "STREAM_READRATE_BURST" => "60"))
        session = converting(session_for(long))
        bitrate = Playback::Pace.bitrate_of(session.media_file)
        Playback::ShareSpeed.record(root_of(session), bitrate * 3)
        supervisor.request(session.id, 0)
        expect(readrate_args(session)).to eq([ "2.0", "24.0" ])
      end

      it "holds a channel tuned ahead while the one on screen is still starting on the same slow share, then starts it" do
        stub_const("#{described_class}::HOLD_EVERY", 0.05)
        watched = session_for(long)
        ahead = PlaybackSession.create!(watched.attributes.except("id", "created_at", "updated_at").merge("standby" => true))
        Playback::ShareSpeed.record(root_of(watched), Playback::Pace.bitrate_of(watched.media_file) * 3)

        supervisor.request(watched.id, 0)
        supervisor.request(ahead.id, 0)
        expect(supervisor.runs).not_to have_key(ahead.id)

        tick_until { supervisor.runs.key?(ahead.id) }
        expect(Playback::Cache.gop_ready?(watched.id, described_class::COLD_GOPS - 1)).to be(true)
      end

      it "doesn't throttle a run that only repackages, which refills at full speed once let go (R2)" do
        allow(Playback::Pace).to receive(:for).and_call_original
        stub_const("#{described_class}::AHEAD_PAUSE_MS", 6_000)
        stub_const("#{described_class}::AHEAD_RESUME_MS", 3_000)
        film = File.join(build_root, "film.mkv")
        ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=160x90:rate=24:duration=900 -f lavfi
          -i sine=frequency=440:duration=900 -c:v libx264 -preset ultrafast -g 48 -keyint_min 48 -c:a aac #{film}])
        session = session_for(film)
        supervisor.request(session.id, 0)
        expect(TranscodeRun.where(playback_session_id: session.id).sole.argv).not_to include("-readrate")
        tick_until { run_of(session).paused }
        sleep 0.3
        made = (0..449).find { |gop| !Playback::Cache.gop_ready?(session.id, gop) }

        # The player asks for the first GOP not made yet: going again, it's
        # well past it within the second — not two seconds of film a second.
        supervisor.request(session.id, made)
        expect(run_of(session).paused).to be(false)
        Timeout.timeout(1.0) { sleep 0.02 until Playback::Cache.gop_ready?(session.id, made + 3) }
      end

      it "doesn't hold a channel tuned ahead on a share that keeps up" do
        watched = session_for(long)
        ahead = PlaybackSession.create!(watched.attributes.except("id", "created_at", "updated_at").merge("standby" => true))
        Playback::ShareSpeed.record(root_of(watched), Playback::Pace.bitrate_of(watched.media_file) * 100)
        supervisor.request(watched.id, 0)
        supervisor.request(ahead.id, 0)
        expect(supervisor.runs).to have_key(ahead.id)
      end
    end

    it "refuses a run when the cache's disk is nearly full, and says so" do
      allow(Playback::Cache).to receive(:free_bytes).and_return(100.megabytes)
      session = session_for(long)
      supervisor.request(session.id, 0)
      expect(session.reload.transcode_error).to include("the transcoder's cache disk is full (100 MB free)")
      expect(supervisor.runs).to be_empty
    end

    it "makes a GOP again that was swept from behind a run still going" do
      session = session_for(long)
      supervisor.request(session.id, 0)
      Timeout.timeout(20) { sleep 0.05 until Playback::Cache.gop_ready?(session.id, 8) }
      supervisor.tick
      first = run_of(session).handle.pid
      FileUtils.rm_f(Playback::Cache.gop(session.id, 3))

      supervisor.request(session.id, 3)

      expect(run_of(session).handle.pid).not_to eq(first)
      expect(run_of(session).start_gop).to eq(3)
      Timeout.timeout(20) { sleep 0.05 until Playback::Cache.gop_ready?(session.id, 3) }
    end

    it "stops a run whose fragments aren't the plan's, and doesn't make the same ones again" do
      session = session_for(long)
      allow_any_instance_of(Playback::Publisher).to receive(:fragment).and_raise(Playback::Publisher::Mismatch, "not what was planned")
      supervisor.request(session.id, 0)
      tick_until { session.reload.transcode_error }
      expect(supervisor.runs).to be_empty

      supervisor.request(session.id, 1)

      expect(supervisor.runs).to be_empty
      expect(TranscodeRun.where(playback_session: session).sole).to have_attributes(failure: "refused")
    end

    it "says why a run couldn't be started, rather than leaving its requests to time out" do
      session = session_for(long)
      allow(Playback::FfmpegArgs).to receive(:build).and_raise(KeyError, "key not found: \"codec\"")
      supervisor.request(session.id, 0)
      expect(session.reload.transcode_error).to eq("ffmpeg couldn't be started: key not found: \"codec\"")
      expect(TranscodeRun.find_by!(playback_session: session)).to have_attributes(failure: "unstartable", state: "exited")
      expect(supervisor.runs).to be_empty
    end
  end

  it "ends a channel tuned ahead that nobody has touched in half an hour, and leaves a paused play alone" do
    standby = session_for(copy_fixture("h264_aac_ac3_subs.mkv"))
    standby.update!(standby: true, last_seen_at: 40.minutes.ago)
    paused = session_for(copy_fixture("h264_dts.mkv"))
    paused.update!(last_seen_at: 3.hours.ago)
    fresh = session_for(copy_fixture("h264_aac.mp4"))
    fresh.update!(standby: true, last_seen_at: 1.minute.ago)

    supervisor.tick

    expect([ standby, paused, fresh ].map { |session| session.reload.state }).to eq(%w[ended active active])
  end

  it "keeps the run of a channel tuned ahead that has gone quiet, and stops a quiet play's (APPLETV_STALLS R3)" do
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache, "STREAM_READRATE_BURST" => "4"))
    keep_throttled
    film = File.join(build_root, "film.mkv")
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=160x90:rate=24:duration=120 -f lavfi
      -i sine=frequency=440:duration=120 -c:v libx264 -preset ultrafast -g 48 -keyint_min 48 -c:a aac #{film}])
    ahead = session_for(film)
    ahead.update!(standby: true)
    quiet = PlaybackSession.create!(ahead.attributes.except("id", "created_at", "updated_at").merge("standby" => false))
    supervisor.request(ahead.id, 0)
    supervisor.request(quiet.id, 0)
    [ ahead, quiet ].each { |session| session.update_columns(last_seen_at: 5.minutes.ago) }

    supervisor.tick

    expect(supervisor.runs.keys).to include(ahead.id)
    expect(supervisor.runs.keys).not_to include(quiet.id)
  end

  # The sweep runs on its own thread in bin/transcoder, from outside.
  it "sweeps the fragments of sessions long over, leaving the ones still running" do
    stale = Playback::Cache.directory(SecureRandom.uuid)
    FileUtils.mkdir_p(stale)
    File.write(stale.join("gop-0.m4s"), "x")
    FileUtils.touch(stale, mtime: 1.hour.ago.to_time)
    session = session_for(copy_fixture("h264_aac_ac3_subs.mkv"))
    supervisor.request(session.id, 0)
    FileUtils.touch(Playback::Cache.directory(session.id), mtime: 1.hour.ago.to_time)
    session.update_columns(last_seen_at: 1.hour.ago)

    supervisor.sweep

    expect(stale).not_to exist
    expect(Playback::Cache.directory(session.id)).to exist
  end

  it "stops the run of a session that ended, and records a failed run's error" do
    session = session_for(copy_fixture("h264_aac_ac3_subs.mkv"))
    supervisor.request(session.id, 0)
    session.end!
    supervisor.tick
    expect(supervisor.runs).to be_empty

    broken = session_for(copy_fixture("h264_dts.mkv"))
    File.write(broken.media_file.path, "not a video any more")
    settle_library_roots!
    supervisor.request(broken.id, 0)
    100.times do
      supervisor.tick
      break if supervisor.runs.empty?

      sleep 0.1
    end
    expect(broken.reload.transcode_error).to start_with("ffmpeg exited")
  end
end
