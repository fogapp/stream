# typed: false
# frozen_string_literal: true

require "rails_helper"

# One file of each format, every way the
# server can play it, once per version — and what it finds is learned by
# every kind of client.
RSpec.describe PlayabilitySweepJob do
  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
  end

  after { FileUtils.rm_rf(@cache) }

  let(:household) { Household.create!(name: "Sweep") }

  def probed(name, fixture)
    root = build_root(name => fixture)
    path = File.join(root, name)
    file = MediaFile.create!(household: household, library: create_library(household: household, roots: root), path: path,
      size: File.size(path), mtime: Time.current, state: "discovered")
    Media::FileProber.new(file).call
    file.reload
  end

  # The sweep's own read stands still with the rest of the heavy queue, and
  # never runs beside the one read over the file.
  it "indexes a sample under the heavy queue's hold, and leaves it for later when the file's being read" do
    ts = probed("c.ts", "torture/recording_offset.ts")
    hold = -> { false }
    allow(HoldHeavyWhileWatchingJob).to receive(:hold).and_return(hold)
    allow(Media::OnePass).to receive(:exclusively).and_return(nil)
    allow(Media::KeyframeIndex).to receive(:scan!)

    described_class.perform_now

    expect(Media::KeyframeIndex).not_to have_received(:scan!)
    expect(Playability.count).to eq(0)

    allow(Media::OnePass).to receive(:exclusively).and_yield
    described_class.perform_now

    expect(Media::KeyframeIndex).to have_received(:scan!).with(ts, hold: hold)
  end

  # One the server can't answer for (nothing it could do to it) has no row
  # to show for its go, and took a place in every run after.
  it "moves on from a format no way of playing could be tried on" do
    stub_const("PlayabilitySweepJob::PER_RUN", 1)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    silent = probed("a.mkv", "h264_aac_ac3_subs.mkv")
    other = probed("c.ts", "torture/recording_offset.ts")
    allow(Playback::Trial).to receive(:new).and_wrap_original do |original, file, rung|
      file.id == silent.id ? instance_double(Playback::Trial, run: nil) : original.call(file, rung)
    end

    3.times { described_class.perform_now }

    expect(Playability.where(client_class: "server").distinct.pluck(:format_signature)).to include(Playback::Learned.signature(other))
    expect(Rails.cache.read([ "playability_sweep:done", household.id, described_class.version ])).to be_present
  end

  it "tries each format once a version, records what the server found, and teaches every client a failure" do
    mkv = probed("a.mkv", "h264_aac_ac3_subs.mkv")
    probed("b.mkv", "h264_aac_ac3_subs.mkv")
    ts = probed("c.ts", "torture/recording_offset.ts")

    described_class.perform_now
    server = Playability.where(client_class: "server")
    expect(server.distinct.pluck(:format_signature).size).to eq(2)
    expect(server.pluck(:rung).uniq).to contain_exactly("remux", "audio_transcode", "video_transcode_software")
    expect(server.where.not(last_failed_at: nil)).to be_empty
    # One file stands for each format.
    expect(server.group(:format_signature).distinct.count(:media_file_id).values).to all(eq(1))
    expect(server.where(format_signature: Playback::Learned.signature(ts)).count).to eq(3)

    # The same version: nothing more to try.
    expect { described_class.perform_now }.not_to(change { Playability.sum(:successes) })
    # And with nothing probed since, the library isn't read again.
    allow(Playback::Learned).to receive(:signature).and_call_original
    described_class.perform_now
    expect(Playback::Learned).not_to have_received(:signature)

    # A failure the server found is skipped for any client.
    server.where(format_signature: Playback::Learned.signature(mkv), rung: "remux").update_all( # rubocop:disable Rails/SkipsModelValidations
      last_failed_at: Time.current, last_succeeded_at: 1.day.ago, last_failure_class: "server", last_failure_cause: "ffmpeg exited 1")
    constraints, why = Playback::Learned.constraints_for(mkv.reload, "Chrome 141 on macOS")
    expect(constraints.convert_audio).to be(true)
    expect(why).to eq("Repackaging failed when the server tried a file like this — skipped")
  end
end
