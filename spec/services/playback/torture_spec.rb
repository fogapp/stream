# typed: false
# frozen_string_literal: true

require "rails_helper"

# Files shaped the ways real libraries break players
# (bin/torture-fixtures), each played
# every way the server can play it, with the production arguments, the
# real Publisher, and the result decoded end to end (Playback::Trial). On
# CI that's jellyfin-ffmpeg, what production runs.
RSpec.describe Playback::Trial do
  before do
    require_ffprobe!
    @cache = Dir.mktmpdir("stream-cache")
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
  end

  after { FileUtils.rm_rf(@cache) }

  let(:household) { Household.create!(name: "Torture") }

  def probed(name)
    root = build_root(name => "torture/#{name}")
    library = create_library(household: household, roots: root)
    path = File.join(root, name)
    file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current,
      state: "discovered")
    expect(Media::FileProber.new(file).call).to eq(Media::FileProber::Outcome::Probed)
    file.reload
    times, source = Media::KeyframeIndex.from_container(file)
    Media::KeyframeIndex.store(file, times || Media::Keyframes::PacketScan.keyframes_ms(file.path, stream: file.primary_video&.index),
      source || Media::KeyframeIndex::Source::Packets)
    file.reload
  end

  Dir[Rails.root.join("spec/fixtures/media/torture/*")].map { |path| File.basename(path) }.sort.each do |name|
    it "plays #{name} every way the server can" do
      file = probed(name)
      outcomes = described_class::RUNGS.keys.filter_map { |rung| described_class.new(file, rung).run }
      expect(outcomes).not_to be_empty
      outcomes.each { |outcome| expect(outcome.cause).to be_nil, "#{outcome.rung}: #{outcome.cause}" }
    end
  end

  it "knows what each fixture is about" do
    expect(probed("avchd_interlaced_422.mts").primary_video).to have_attributes(field_order: "tt", chroma: "422")
    expect(probed("screen_444.mkv").primary_video.chroma).to eq("444")
    expect(probed("phone_rotated.mov").primary_video.rotation.to_i.abs).to eq(90)
    expect(probed("recording_offset.ts").start_time).to be > 95_000
    expect(probed("flac_96k.mkv").media_streams.find { |stream| stream.kind == "audio" }.sample_rate).to eq(96_000)
    commentary = probed("commentary_first.mkv")
    expect(Playback::Decision.new(commentary, described_class::CAPABILITIES).audio.index).to eq(2)
  end
end
