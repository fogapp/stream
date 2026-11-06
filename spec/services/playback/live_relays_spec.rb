# typed: false
# frozen_string_literal: true

require "rails_helper"

# The transcoder's live relays (PROPOSAL §7.8), with ffmpeg stubbed: one per
# stream and decision, shared; idle ones stopped; a dropped source
# reconnected with backoff, said in words without its address.
RSpec.describe Playback::LiveRelays do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { Household.create!(name: "Family") }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:token) { "AbCdEfGhIjKlMnOp" }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera", trust_certificate: true,
      url: "rtsps://192.168.1.1:7441/#{token}?enableSrtp").tap do |live|
      live.media_streams.create!(index: 0, kind: "audio", codec: "aac", channels: 1)
      live.media_streams.create!(index: 1, kind: "video", codec: "h264", bit_depth: 8, height: 2160)
    end
  end
  let(:profile) { Profile.default_for(household) }
  let(:caps) { Playback::Capabilities.from_json("video" => %w[h264], "audio" => %w[aac]) }
  let(:spawned) { [] }
  let(:exits) { {} }
  # Made before anything's wanted: a new one clears what an earlier transcoder left.
  let!(:relays) { described_class.new(log: ->(_) { }) }

  def session_for(live = stream)
    decision = Playback::Decision.live(live, caps)
    PlaybackSession.create!(household: household, profile: profile, playable: live, method: decision.method.serialize, decision: decision.to_h,
      started_at: Time.current, last_seen_at: Time.current)
  end

  around do |example|
    Dir.mktmpdir("stream-cache") do |cache|
      @cache = cache
      example.run
    end
  end

  before do
    allow(Playback::FfmpegArgs::Input).to receive(:rtsp_tls_verify?).and_return(true)
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    allow(Playback::Runner).to receive(:spawn_local) do |argv, log:, redact:|
      spawned << { argv: argv, log: log, redact: redact }
      Playback::Runner::LocalHandle.new(pid: spawned.size)
    end
    allow(Playback::Runner).to receive(:poll) { |handle| exits.delete(handle.pid) }
    allow(Playback::Runner).to receive(:kill)
  end

  it "starts one relay per stream and decision, whoever asks, and redacts what ffmpeg says" do
    first = session_for
    second = session_for
    relays.request(first.id)
    relays.request(second.id)
    relays.request(first.id)

    expect(spawned.size).to eq(1)
    expect(spawned.sole[:argv]).to include("rtsps://192.168.1.1:7441/#{token}?enableSrtp")
    expect(spawned.sole[:redact].call("#{token} said no")).to eq("… said no")
    expect(Playback::LiveCache.status(Playback::LiveCache.key_for(first)).state).to eq("starting")
  end

  it "goes live with its first segment, then stops a minute after nobody's fetched its playlist" do
    session = session_for
    key = Playback::LiveCache.key_for(session)
    Playback::LiveCache.want!(key)
    relays.request(session.id)
    File.write(Playback::LiveCache.playlist(key), "#EXTM3U\n#EXTINF:5.0,\nseg-1.m4s\n")
    stream.update_columns(status: "offline", last_error: "earlier")

    relays.tick
    expect(Playback::LiveCache.status(key).state).to eq("live")
    expect(stream.reload).to have_attributes(status: "online", last_error: nil)

    travel 61.seconds do
      relays.tick
    end
    expect(Playback::Runner).to have_received(:kill)
    expect(relays.relays).to be_empty
    expect(Playback::LiveCache.directory(key)).not_to exist
  end

  it "rides out a playlist read that misses, and restarts one that's stopped moving" do
    session = session_for
    key = Playback::LiveCache.key_for(session)
    Playback::LiveCache.want!(key)
    relays.request(session.id)
    playlist = Playback::LiveCache.playlist(key)
    File.write(playlist, "#EXTM3U\n#EXTINF:5.0,\nseg-1.m4s\n")
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
    allow(relays).to receive(:monotonic) { clock }
    relays.tick
    expect(Playback::LiveCache.status(key).state).to eq("live")

    # A segment a killed run left behind is cleared once a minute.
    orphan = Playback::LiveCache.directory(key).join("seg-0.m4s")
    File.write(orphan, "x")
    File.utime(Time.now - 600, Time.now - 600, orphan) # rubocop:disable Rails/TimeZone
    # Long after it started, ffmpeg's rename leaves nothing to read for a tick.
    clock += 120
    relays.tick
    expect(orphan).not_to exist
    clock += 1
    File.delete(playlist)
    relays.tick
    expect(Playback::Runner).not_to have_received(:kill)

    File.write(playlist, "#EXTM3U\n#EXTINF:5.0,\nseg-2.m4s\n")
    relays.tick
    expect(Playback::LiveCache.status(key).state).to eq("live")

    clock += 31
    File.utime(Time.now - 31, Time.now - 31, playlist)
    relays.tick
    expect(Playback::Runner).to have_received(:kill)
    expect(Playback::LiveCache.status(key)).to have_attributes(state: "reconnecting", message: "The stream stopped sending")
  end

  it "reconnects a dropped source after a wait, appending to its playlist, and says why without the address" do
    session = session_for
    key = Playback::LiveCache.key_for(session)
    Playback::LiveCache.want!(key)
    relays.request(session.id)
    File.write(Playback::LiveCache.playlist(key), "#EXTM3U\n#EXTINF:5.0,\nseg-1.m4s\n")
    File.write(Playback::LiveCache.directory(key).join("ffmpeg.log"), "[tls] Error in the pull function.\n… : Connection refused\n")
    exits[1] = Playback::Runner::Exit.new(status: 1)

    relays.tick
    status = Playback::LiveCache.status(key)
    expect(status).to have_attributes(state: "reconnecting", message: "Nothing answered at rtsps://192.168.1.1:7441")
    expect(stream.reload).to have_attributes(status: "offline", consecutive_failures: 1)
    expect(ActivityEntry.where(event: "live_stream.dropped").sole.summary).to include("Front door")
    expect(spawned.size).to eq(1)

    allow(relays).to receive(:monotonic).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f + 2)
    relays.tick
    expect(spawned.size).to eq(2)
    expect(spawned.last[:argv][spawned.last[:argv].index("-hls_flags") + 1]).to include("append_list")
    expect(Playback::LiveCache.status(key).state).to eq("reconnecting")
  end

  it "keeps a kept-connected stream relayed with nobody watching" do
    stream.update!(keep_connected: true)

    relays.tick
    expect(spawned.size).to eq(1)
    key = relays.relays.keys.sole
    expect(Playback::LiveCache.wanted_at(key)).to be_within(5).of(Time.current)

    travel 61.seconds do
      allow(relays).to receive(:monotonic).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f + 61)
      relays.tick
    end
    expect(relays.relays.keys).to eq([ key ])
  end

  context "with a YouTube stream" do
    let(:youtube) do
      LiveStream.create!(household: household, library: library, name: "Lofi Girl", kind: "youtube", url: "https://youtu.be/rFZHOHl-L8A").tap do |live|
        live.media_streams.create!(index: 0, kind: "video", codec: "h264", bit_depth: 8, height: 1080)
        live.media_streams.create!(index: 1, kind: "audio", codec: "aac", channels: 2)
      end
    end
    let(:resolved) do
      LiveStreams::Resolved.new(video: "https://example.googlevideo.com/v.m3u8", audio: "https://example.googlevideo.com/a.m3u8")
    end

    # Waits for yt-dlp's thread; what it raised is the relay's to read.
    def settle
      relays.relays.each_value do |relay|
        relay.resolving&.join
      rescue StandardError
        nil
      end
    end

    it "asks yt-dlp off the loop, starts on the tick after, and asks again after a drop" do
      allow(LiveStreams::YoutubeSource).to receive(:resolve).and_return(resolved)
      allow(LiveStreams::YoutubeSource).to receive(:forget)
      session = session_for(youtube)
      key = Playback::LiveCache.key_for(session)
      Playback::LiveCache.want!(key)

      relays.request(session.id)
      expect(spawned).to be_empty
      expect(Playback::LiveCache.status(key).state).to eq("starting")
      settle
      relays.tick
      expect(spawned.sole[:argv]).to include(resolved.video, resolved.audio)

      exits[1] = Playback::Runner::Exit.new(status: 1)
      relays.tick
      expect(LiveStreams::YoutubeSource).to have_received(:forget).with(youtube)
      allow(relays).to receive(:monotonic).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f + 2)
      relays.tick
      settle
      relays.tick
      expect(spawned.size).to eq(2)
      expect(LiveStreams::YoutubeSource).to have_received(:resolve).twice
    end

    it "says why, and tries again later, when YouTube has no stream" do
      allow(LiveStreams::YoutubeSource).to receive(:resolve).and_raise(LiveStreams::Prober::Failure, "Lofi Girl isn't live on YouTube right now")
      session = session_for(youtube)
      key = Playback::LiveCache.key_for(session)
      Playback::LiveCache.want!(key)

      relays.request(session.id)
      settle
      relays.tick
      expect(spawned).to be_empty
      expect(Playback::LiveCache.status(key)).to have_attributes(state: "reconnecting", message: "Lofi Girl isn't live on YouTube right now")
      expect(youtube.reload).to have_attributes(status: "offline", last_error: "Lofi Girl isn't live on YouTube right now")
    end
  end
end
