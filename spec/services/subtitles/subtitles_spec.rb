# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Subtitles" do
  before do
    require_ffprobe!
    @storage = Dir.mktmpdir("stream-storage")
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => @storage))
  end

  after { FileUtils.rm_rf(@storage) }

  let(:household) { Household.create!(name: "Subs") }
  let(:root) { build_root("Heat (1995)/Heat (1995).mkv" => "h264_aac_ac3_subs.mkv") }
  let(:video_path) { File.join(root, "Heat (1995)/Heat (1995).mkv") }
  let(:file) do
    library = create_library(household: household, roots: root)
    record = MediaFile.create!(household: household, library: library, path: video_path, size: File.size(video_path),
      mtime: Time.current, state: "discovered")
    Media::FileProber.new(record).call
    record.reload
  end

  def sidecar(name, body)
    File.write(File.join(root, "Heat (1995)", name), body)
  end

  SRT = "1\n00:00:00,500 --> 00:00:01,500\nFrom the sidecar.\n"

  describe Subtitles::Tracks do
    it "lists embedded text tracks with their language and forced flag" do
      tracks = described_class.embedded(file)
      expect(tracks.map { |t| [ t.id, t.format.serialize, t.language, t.forced ] })
        .to eq([ [ "e3", "vtt", "eng", false ], [ "e4", "ass", "jpn", true ] ])
    end

    it "finds sidecars named the Plex way, reading language, forced and SDH from the name" do
      sidecar("Heat (1995).en.srt", SRT)
      sidecar("Heat (1995).es.forced.srt", SRT)
      sidecar("Heat (1995).en.sdh.srt", SRT)
      sidecar("Other Movie.en.srt", SRT)
      sidecar("Heat (1995).nfo", "")

      found = described_class.sidecars(file).map { |t| [ t.language, t.forced, t.hearing_impaired ] }
      expect(found).to contain_exactly([ "en", false, false ], [ "es", true, false ], [ "en", false, true ])
    end

    # docs/PERF_PROPOSAL.md › P3: pressing Play never lists a folder on the NAS.
    it "lists the folder once and keeps what it found, reading only that from then on" do
      sidecar("Heat (1995).en.srt", SRT)
      expect(described_class.sidecars(file).map(&:language)).to eq([ "en" ])
      expect(file.reload.sidecar_subtitles).to eq([ "Heat (1995).en.srt" ])

      allow(Dir).to receive(:children).and_raise(Errno::EIO)
      sidecar("Heat (1995).fr.srt", SRT)
      settle_library_roots!
      expect(described_class.sidecars(file.reload).map(&:language)).to eq([ "en" ])
    end
  end

  describe Subtitles::Extractor do
    it "extracts an embedded SubRip track as WebVTT, once" do
      track = Subtitles::Tracks.find(file, "e3")
      path = described_class.fetch(file, track, "vtt")

      expect(path.read).to start_with("WEBVTT").and include("Hello from the corpus.")
      expect(ToolRunner).not_to receive(:run_advancing)
      described_class.fetch(file, track, "vtt")
    end

    it "keeps ASS styling for JASSUB and makes a WebVTT fallback" do
      track = Subtitles::Tracks.find(file, "e4")
      expect(described_class.fetch(file, track, "ass").read).to include("[V4+ Styles]", "Styled")
      expect(described_class.fetch(file, track, "vtt").read).to start_with("WEBVTT")
    end

    it "converts a sidecar SRT to WebVTT" do
      sidecar("Heat (1995).en.srt", SRT)
      track = Subtitles::Tracks.sidecars(file).sole
      expect(described_class.fetch(file, track, "vtt").read).to include("From the sidecar.")
    end

    it "pulls every embedded track out in the one read over the file, and queues what follows" do
      allow(ToolRunner).to receive(:each_line).and_call_original
      AnalyzeMediaFileJob.perform_now(file.id)
      expect(ToolRunner).to have_received(:each_line).once
      expect(file.analysis_runs.find_by(step: "subtitles").status).to eq("succeeded")
      expect(Dir.children(described_class.root.join(file.id)).sort).to eq(%w[e3.vtt e4.ass e4.vtt])
      expect(BuildTranscriptJob).to have_been_enqueued.with(file.id)
      expect(FetchSubtitlesJob).to have_been_enqueued.with(file.id)
    end

    # Nothing to read, but the transcript and the fetch still follow, and
    # the step is done: a loudness rerun later doesn't queue them again.
    it "finishes the step for a file with nothing embedded, and queues what follows once" do
      file.media_streams.where(kind: "subtitle").delete_all
      file.update!(probe: file.probe.merge("streams" => file.probe["streams"].reject { |stream| stream["codec_type"] == "subtitle" }))
      file.reload

      expect(ToolRunner).not_to receive(:each_line)
      expect(ToolRunner).not_to receive(:run_advancing)
      stub_const("Media::OnePass::QUIET_TIMEOUT", 30)
      allow(Media::OnePass).to receive(:parts_for).and_wrap_original { |m, *args| m.call(*args).select { |part| part.step == AnalysisRun::Step::Subtitles } }
      AnalyzeMediaFileJob.perform_now(file.id)
      expect(file.analysis_runs.find_by(step: "subtitles").status).to eq("succeeded")
      expect(BuildTranscriptJob).to have_been_enqueued.with(file.id).once

      clear_enqueued_jobs
      AnalyzeMediaFileJob.perform_now(file.id)
      expect(BuildTranscriptJob).not_to have_been_enqueued
    end

    it "reads a silent file's tracks without the audio to keep time by" do
      silent = File.join(root, "Heat (1995)/Silent.mkv")
      srt = File.join(root, "Heat (1995)/silent.srt")
      File.write(srt, SRT)
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc=duration=2:size=64x48 -i #{srt} -map 0 -map 1 -c:v libx264
        -c:s srt #{silent}])
      File.delete(srt)
      record = MediaFile.create!(household: household, library: file.library, path: silent, size: File.size(silent),
        mtime: Time.current, state: "discovered")
      Media::FileProber.new(record).call

      expect(Media::OnePass.run(record.reload)).to include(AnalysisRun::Step::Subtitles)
      expect(Dir.children(described_class.root.join(record.id))).to eq(%w[e1.vtt])
    end

    # Backups leave image tracks and embedded fonts out; a restore sends a
    # file missing either back through the background job.
    it "requeues a file whose image track didn't come back from a restore" do
      file.media_streams.find_by(index: 3).update!(codec: "hdmv_pgs_subtitle")

      expect { described_class.requeue_missing! }.to have_enqueued_job(AnalyzeMediaFileJob).with(file.id).exactly(:once)
      described_class.root.join(file.id).mkpath
      described_class.root.join(file.id, "e3.sup").write("pgs")
      expect { described_class.requeue_missing! }.not_to have_enqueued_job(AnalyzeMediaFileJob)
    end

    it "puts back embedded fonts a restore left behind, even with every track already out" do
      font = File.join(root, "Styled.ttf")
      File.write(font, "not really a font")
      with_font = File.join(root, "Heat (1995)/Heat (1995).fonts.mkv")
      ToolRunner.run(%W[ffmpeg -v error -y -i #{video_path} -map 0 -c copy -attach #{font}
        -metadata:s:t mimetype=application/x-truetype-font #{with_font}])
      record = MediaFile.create!(household: household, library: file.library, path: with_font, size: File.size(with_font),
        mtime: Time.current, state: "discovered")
      Media::FileProber.new(record).call
      record.reload

      Media::OnePass.run(record)
      expect(described_class.fonts(record).map { |path| path.basename.to_s }).to eq(%w[Styled.ttf])

      FileUtils.rm_rf(described_class.root.join(record.id, "fonts"))
      expect { described_class.requeue_missing! }.to have_enqueued_job(AnalyzeMediaFileJob).with(record.id)
      expect(Media::OnePass.run(record)).to eq([ AnalysisRun::Step::Subtitles ])
      expect(described_class.fonts(record).map { |path| path.basename.to_s }).to eq(%w[Styled.ttf])
      expect(Dir.children(described_class.root.join(record.id)).sort).to eq(%w[e3.vtt e4.ass e4.vtt fonts])
    end
  end

  describe "serving", type: :request do
    it "lists subtitles on the session and serves them" do
      sidecar("Heat (1995).fr.srt", SRT)
      user = create_user(household: household)
      movie = Movie.create!(household: household, library: file.library, title: "Heat")
      movie.editions.create!(media_file: file)

      post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id,
        capabilities: { hls: "mse", video: %w[h264], audio: %w[aac] } }, headers: auth_headers(user), as: :json
      subtitles = json["subtitles"]
      expect(subtitles.map { |s| [ s["language"], s["format"], s["external"] ] })
        .to eq([ [ "eng", "vtt", false ], [ "jpn", "ass", false ], [ "fr", "vtt", true ] ])

      # Not taken out yet: a job does it, and the player is told to ask
      # again rather than held while the file is read (APPLETV_STALLS R5).
      stub_const("ServesSubtitles::SUBTITLE_WAIT", 0.1)
      url = subtitles.first.dig("urls", "vtt")
      get url
      expect(response).to have_http_status(:service_unavailable)
      expect(response.headers["Retry-After"]).to eq("10")
      expect(ExtractSubtitleTrackJob).to have_been_enqueued.with(file.id, "e3", "vtt")

      perform_enqueued_jobs
      get url
      expect(response.media_type).to eq("text/vtt")
      expect(response.body).to include("Hello from the corpus.")

      get url.sub("e3.vtt", "e9.vtt")
      expect(response).to have_http_status(:not_found)
    end

    it "says at once why a track couldn't be taken out, rather than reading the file again" do
      user = create_user(household: household)
      movie = Movie.create!(household: household, library: file.library, title: "Heat")
      movie.editions.create!(media_file: file)
      post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id,
        capabilities: { hls: "mse", video: %w[h264], audio: %w[aac] } }, headers: auth_headers(user), as: :json
      url = json["subtitles"].first.dig("urls", "vtt")
      allow(Subtitles::Extractor).to receive(:extract).and_raise(Subtitles::Extractor::Error, "ffmpeg wrote nothing for e3")

      stub_const("ServesSubtitles::SUBTITLE_WAIT", 0.1)
      get url
      expect(response).to have_http_status(:service_unavailable)
      perform_enqueued_jobs
      get url
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to eq("ffmpeg wrote nothing for e3")
      expect(ExtractSubtitleTrackJob).not_to have_been_enqueued.with(file.id, "e3", "vtt").exactly(2).times
      expect(Subtitles::Extractor).to have_received(:extract).once
    end
  end
end
