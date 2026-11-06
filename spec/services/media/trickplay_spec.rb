# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trickplay and chapters" do
  before do
    require_ffprobe!
    @storage = Dir.mktmpdir("stream-storage")
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => @storage))
  end

  after { FileUtils.rm_rf(@storage) }

  let(:household) { Household.create!(name: "Trick") }

  # 45 s with three chapters, the way a Blu-ray rip carries them.
  let(:path) do
    dir = build_root
    meta = File.join(dir, "chapters.txt")
    File.write(meta, <<~META)
      ;FFMETADATA1
      [CHAPTER]
      TIMEBASE=1/1000
      START=0
      END=15000
      title=Opening
      [CHAPTER]
      TIMEBASE=1/1000
      START=15000
      END=30000
      title=The heist
      [CHAPTER]
      TIMEBASE=1/1000
      START=30000
      END=45000
      title=Aftermath
    META
    out = File.join(dir, "movie.mkv")
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=640x360:rate=24:duration=45 -i #{meta} -map_metadata 1
      -c:v libx264 -preset ultrafast -g 48 #{out}])
    out
  end

  let(:file) do
    record = MediaFile.create!(household: household, library: create_library(household: household, roots: File.dirname(path)),
      path: path, size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(record).call
    record.reload
  end

  it "spaces thumbnails 10 s apart for anything film-length, closer for short clips" do
    expect(Media::TrickplayBuilder.interval_for(7200.0)).to eq(10)
    expect(Media::TrickplayBuilder.interval_for(45.0)).to eq(5)
    expect(Media::TrickplayBuilder.interval_for(2.0)).to eq(1)
  end

  # VP9's decoder ignores -skip_frame and WebM's demuxer ignores -discard, so
  # without the bitstream filter a VP9 file decodes every frame — 48 here, a
  # whole film's worth in production — and runs past its timeout.
  it "decodes only keyframes, VP9 in WebM included" do
    %w[vp9_opus.webm av1_opus.webm hevc_main10_hdr10.mkv h264_aac.mp4].each do |fixture|
      source = media_fixture(fixture)
      keyframes = ToolRunner.run(%W[ffprobe -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 #{source}])
        .stdout.lines.count { |flags| flags.start_with?("K") }
      decoded = ToolRunner.run([ "ffmpeg", "-hide_banner", "-nostdin", *Media::OnePass::KEYFRAMES_ONLY, "-i", source,
        "-map", "0:v:0", "-vf", "showinfo", "-f", "null", "-" ]).stderr.scan(/\bn:\s*\d+/).size
      expect(decoded).to eq(keyframes), "#{fixture}: decoded #{decoded} frames, #{keyframes} keyframes"
    end
  end

  it "renders a VP9 WebM's thumbnails" do
    root = build_root("Clips/clip.webm" => "vp9_opus.webm")
    vp9 = MediaFile.create!(household: household, library: create_library(household: household, roots: root),
      path: File.join(root, "Clips/clip.webm"), size: File.size(media_fixture("vp9_opus.webm")), mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(vp9).call

    AnalyzeMediaFileJob.perform_now(vp9.id)
    expect(vp9.reload.trickplay).to have_attributes(version: 1, sheet_count: 1)
    expect(vp9.trickplay.sheet(0)).to be_file
  end

  # A busy share is slow, not stuck: the read gets as long as it takes, and
  # only a read that stops advancing is given up on. A FIFO plays the share,
  # fed in chunks; the clip keyframes every half second so the decoder's
  # threads hold back little of it.
  describe "reading from a slow share" do
    let(:clip) do
      out = File.join(build_root, "clip.mkv")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=640x360:rate=24:duration=45 -c:v libx264 -preset ultrafast
        -g 12 #{out}])
      out
    end

    let(:share_file) do
      record = MediaFile.create!(household: household, library: create_library(household: household, roots: File.dirname(clip)),
        path: clip, size: File.size(clip), mtime: Time.current, state: "discovered")
      Media::FileProber.new(record).call
      @share = Dir.mktmpdir("stream-share")
      record.reload.tap { |probed| probed.update_column(:path, File.join(@share, "clip.mkv")) }
    end

    def feed(chunks:, pause:, stop_after: chunks)
      File.mkfifo(share_file.path)
      bytes = File.binread(clip)
      size = (bytes.bytesize / chunks.to_f).ceil
      @writer = Thread.new do
        File.open(share_file.path, "wb") do |io|
          stop_after.times do |index|
            io.write(bytes.byteslice(index * size, size))
            io.flush
            sleep pause
          end
          sleep 10 if stop_after < chunks
        end
      rescue Errno::EPIPE
        nil
      end
    end

    after do
      @writer&.kill
      FileUtils.rm_rf(@share) if @share
    end

    it "waits out a read that takes longer than the stall window, as long as it advances" do
      # Longer than the read's pauses, and than encoding the sheet at its end.
      stub_const("Media::OnePass::QUIET_TIMEOUT", 8)
      feed(chunks: 10, pause: 1)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Media::OnePass.run(share_file)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be > 8
      expect(share_file.reload.trickplay).to have_attributes(version: 1, sheet_count: 1, thumbnail_count: 9)
    end

    it "gives up on a read that stops, and leaves nothing behind" do
      stub_const("Media::OnePass::QUIET_TIMEOUT", 2)
      feed(chunks: 10, pause: 0.3, stop_after: 5)

      expect { Media::OnePass.run(share_file) }.to raise_error(ToolRunner::Timeout, /went quiet for 2s/)
      expect(Trickplay.find_or_initialize_by(media_file: share_file).directory.glob("*/*")).to be_empty
      expect(share_file.analysis_runs.where(status: "failed").map(&:step)).to include("trickplay", "subtitles")
    end
  end

  it "keeps the container's chapters from the probe" do
    expect(file.chapters).to eq([
      { "start" => 0.0, "end" => 15.0, "title" => "Opening" },
      { "start" => 15.0, "end" => 30.0, "title" => "The heist" },
      { "start" => 30.0, "end" => 45.0, "title" => "Aftermath" }
    ])
  end

  it "renders a sprite sheet of thumbnails (every 5 s for a 45 s clip), and replaces it on a re-render" do
    AnalyzeMediaFileJob.perform_now(file.id)
    trickplay = file.reload.trickplay
    expect(trickplay).to have_attributes(version: 1, interval_seconds: 5, tile_width: 320, tile_height: 180, sheet_count: 1,
      thumbnail_count: 9)
    expect(trickplay.sheet(0)).to be_file
    size = ToolRunner.run(%W[ffprobe -v error -show_entries stream=width,height -of csv=p=0 #{trickplay.sheet(0)}]).stdout.strip
    expect(size).to eq("3200,1800")
    expect(file.analysis_runs.find_by(step: "trickplay").status).to eq("succeeded")

    first = trickplay.sheet(0)
    Analysis::Rerun.call(file, AnalysisRun::Step::Trickplay)
    AnalyzeMediaFileJob.perform_now(file.id)
    expect(trickplay.reload.version).to eq(2)
    expect(first).not_to exist
  end

  # Backups leave the sheets out; a restore rebuilds the ones that didn't
  # come back, and the player isn't offered them in the meantime.
  it "requeues a trickplay whose sheets are gone after a restore" do
    AnalyzeMediaFileJob.perform_now(file.id)
    trickplay = file.reload.trickplay
    FileUtils.rm_rf(trickplay.directory)

    expect { Trickplay.requeue_missing! }.to have_enqueued_job(AnalyzeMediaFileJob).with(file.id).exactly(:once)
    expect(trickplay.reload.version).to eq(0)
    expect(PlaybackSessionSerializer.trickplay_json(trickplay, "/media/s/x")).to be_nil

    AnalyzeMediaFileJob.perform_now(file.id)
    expect(trickplay.reload).to have_attributes(version: 1)
    expect(trickplay.sheet(0)).to be_file
    expect { Trickplay.requeue_missing! }.not_to have_enqueued_job(AnalyzeMediaFileJob)
  end

  it "offers both on the playback session, and serves the sheet", type: :request do
    AnalyzeMediaFileJob.perform_now(file.id)
    movie = Movie.create!(household: household, library: file.library, title: "Heist")
    movie.editions.create!(media_file: file)

    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id,
      capabilities: { hls: "mse", video: %w[h264], audio: %w[aac] } }, headers: auth_headers(create_user(household: household)), as: :json

    expect(json["chapters"].map { |c| c["title"] }).to eq([ "Opening", "The heist", "Aftermath" ])
    expect(json["trickplay"]).to include("interval" => 5, "columns" => 10, "count" => 9)
    sheet_url = json.dig("trickplay", "sheet_url")
    get sheet_url.sub("{index}", "0")
    expect(response.media_type).to eq("image/webp")
    get sheet_url.sub("{index}", "1")
    expect(response).to have_http_status(:not_found)
  end
end
