# typed: false
# frozen_string_literal: true

require "rails_helper"

# A live stream's card picture (PROPOSAL §7.8): from its relay when one's
# running, else from the source — which says whether it's still there.
RSpec.describe LiveStreams::Still do
  let(:household) { Household.create!(name: "Family") }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:token) { "AbCdEfGhIjKlMnOp" }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera", trust_certificate: true,
      url: "rtsps://192.168.1.1:7441/#{token}?enableSrtp")
  end
  let(:runs) { [] }

  around do |example|
    Dir.mktmpdir("stream-cache") do |cache|
      @cache = cache
      example.run
    end
  end

  before do
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::FfmpegArgs::Input).to receive(:rtsp_tls_verify?).and_return(true)
  end

  def ffmpeg_answers(status: 0, stderr: "")
    allow(ToolRunner).to receive(:run) do |argv, **|
      ToolArgvGuard.check!(argv)
      runs << argv
      File.binwrite(argv.last, "RIFFwebp") if status.zero?
      ToolRunner::Result.new(status: status, stdout: "", stderr: stderr)
    end
  end

  it "takes the picture from the source when nothing's relaying it, and the job marks the stream online" do
    ffmpeg_answers
    stream.update_columns(status: "offline", last_error: "earlier", consecutive_failures: 2)

    CaptureLiveStillJob.perform_now(stream.id)

    expect(runs.sole).to include("rtsps://192.168.1.1:7441/#{token}?enableSrtp", "-frames:v", "libwebp")
    expect(described_class.path(stream.id).binread).to eq("RIFFwebp")
    expect(stream.reload).to have_attributes(status: "online", last_error: nil, consecutive_failures: 0)
    expect(LiveStreams::StillUrl.for(stream)).to match(%r{\A/artwork/live/#{stream.id}/\d+\.webp\?s=\h{24}\z})
  end

  it "takes it from a running relay instead, without asking the camera" do
    ffmpeg_answers
    directory = Playback::LiveCache.root.join("#{stream.id}-abc")
    FileUtils.mkdir_p(directory)
    directory.join("index.m3u8").write("#EXTM3U\n#EXTINF:5.0,\nseg-1.m4s\n#EXTINF:5.0,\nseg-2.m4s\n")
    directory.join("init.mp4").binwrite("INIT")
    directory.join("seg-2.m4s").binwrite("SEG2")
    directory.join("seg-1.m4s").binwrite("SEG1")

    expect(described_class.capture!(stream)).to eq(:relay)

    argv = runs.sole
    expect(argv.join(" ")).not_to include("rtsps://")
    input = argv[argv.index("-i") + 1]
    expect(argv[argv.index("-protocol_whitelist") + 1]).to eq("file")
    expect(input).to start_with("file:")
  end

  it "marks a source that doesn't answer offline, in words without its address" do
    ffmpeg_answers(status: 1, stderr: "rtsps://192.168.1.1:7441/#{token}?enableSrtp: Connection refused\n")

    CaptureLiveStillJob.perform_now(stream.id)

    expect(stream.reload).to have_attributes(status: "offline", last_error: "Nothing answered at rtsps://192.168.1.1:7441")
    expect(described_class.path(stream.id)).not_to exist
  end
end
