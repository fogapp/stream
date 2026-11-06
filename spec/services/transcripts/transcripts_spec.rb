# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Transcripts" do
  let(:household) { Household.create!(name: "Words") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root, kind: "channels", name: "YouTube") }

  VTT = <<~VTT
    WEBVTT

    1
    00:00:01.000 --> 00:00:03.500
    <v Narrator>So this is the <i>hyperloop</i>.

    00:00:03.500 --> 00:00:05.000
    [MUSIC]

    00:00:05.000 --> 00:00:06.000
    It goes fast.

    00:00:06.000 --> 00:00:07.000
    It goes fast.
  VTT

  def file_with(name, sidecar: nil)
    path = File.join(root, "TC", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "video")
    File.write(path.sub(/\.\w+\z/, ".en.vtt"), sidecar) if sidecar
    MediaFile.create!(household: household, library: library, path: path, size: 5, mtime: Time.current, state: "probed",
      duration_seconds: 60)
  end

  def video_for(file)
    channel = Channel.find_or_create_by!(household: household, library: library, folder: "TC") { |c| c.title = "TC" }
    Video.create!(household: household, library: library, channel: channel, title: File.basename(file.path, ".*"), source: "folder")
      .tap { |video| video.editions.create!(media_file: file) }
  end

  it "reads WebVTT into lines of speech: tags and sound cues dropped, a repeated caption merged" do
    expect(Transcripts::Vtt.parse(VTT)).to eq([
      { start: 1.0, end: 3.5, text: "So this is the hyperloop." },
      { start: 5.0, end: 7.0, text: "It goes fast." }
    ])
  end

  it "builds a file's transcript from its English subtitles, once" do
    file = file_with("Talk.mkv", sidecar: VTT)
    BuildTranscriptJob.perform_now(file.id)

    transcript = file.reload.transcript
    expect(transcript).to have_attributes(source: "subtitles", language: "en", line_count: 2)
    expect(file.analysis_runs.find_by(step: "transcript").status).to eq("succeeded")
    expect(Transcripts::Builder.new(file).call).to eq(Transcripts::Builder::Outcome::Unchanged)
  end

  # A DVB (or DVD) track is pictures: ffmpeg can't make WebVTT of it, and
  # asking failed the step with "Error opening output files".
  it "makes no transcript from picture subtitles" do
    file = file_with("Broadcast.mkv")
    file.media_streams.create!(index: 2, kind: "subtitle", codec: "dvb_subtitle", language: "eng")
    file.media_streams.create!(index: 3, kind: "subtitle", codec: "hdmv_pgs_subtitle", language: "eng")
    allow(ToolRunner).to receive(:run).and_call_original

    BuildTranscriptJob.perform_now(file.id)

    expect(ToolRunner).not_to have_received(:run)
    expect(file.reload.transcript).to be_nil
    expect(file.analysis_runs.find_by(step: "transcript").status).to eq("succeeded")
  end

  it "sends a channel video with no subtitles to Whisper, and offers the result as captions" do
    require_ffprobe!
    source = File.join(build_root("TC/Silent.mp4" => "h264_aac.mp4"), "TC/Silent.mp4")
    file = MediaFile.create!(household: household, library: library, path: source, size: File.size(source), mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(file).call
    video_for(file.reload)
    WhisperSetting.create!(household: household, url: "http://whisper.lan:9000")
    stub_request(:post, "http://whisper.lan:9000/asr?encode=true&output=json&task=transcribe")
      .to_return(status: 200, body: { language: "en", segments: [ { start: 0.5, end: 1.5, text: " Hello there." } ] }.to_json,
        headers: { "Content-Type" => "application/json" })

    perform_enqueued_jobs(only: TranscribeWithWhisperJob) { BuildTranscriptJob.perform_now(file.id) }

    expect(file.reload.transcript).to have_attributes(source: "whisper", language: "en", line_count: 1)
    track = Subtitles::Tracks.for(file).find(&:generated)
    expect(track).to have_attributes(title: "Auto-generated", language: "en")
    storage = Dir.mktmpdir
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => storage))
    expect(Subtitles::Extractor.fetch(file, track, "vtt").read).to eq("WEBVTT\n\n00:00:00.500 --> 00:00:01.500\nHello there.\n")
  end

  it "finds where it was said, with the time and the words around it" do
    file = file_with("Talk.mkv", sidecar: VTT)
    video = video_for(file)
    BuildTranscriptJob.perform_now(file.id)
    Current.household = household

    hits = Viewing::Search.said("hyperloops")

    expect(hits.sole).to include(playable: video, start: 1.0)
    expect(hits.sole[:snippet]).to include("<<hyperloop>>")
  ensure
    Current.reset
  end
end
