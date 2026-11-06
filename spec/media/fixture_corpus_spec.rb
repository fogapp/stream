# typed: false
# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"

# The corpus is only useful if it says what the manifest claims: every media
# spec after this one picks a file by the case it names. This also proves the
# ffprobe on PATH is new enough to read all of it (PROPOSAL §8.4).
RSpec.describe "Media fixture corpus" do
  root = File.expand_path("../fixtures/media", __dir__)
  manifest = JSON.parse(File.read(File.join(root, "manifest.json")))

  ffprobe = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "ffprobe") }.find { |p| File.executable?(p) }

  before do
    # CI installs jellyfin-ffmpeg, so a missing ffprobe there is a failure; on
    # a laptop without ffmpeg it is a pending note rather than a red suite.
    next if ffprobe
    raise "ffprobe is not on PATH" if ENV["CI"]

    skip "ffprobe not on PATH — `brew install ffmpeg`, or run specs in the dev image"
  end

  def probe(ffprobe, path)
    out, err, status = Open3.capture3(ffprobe, "-v", "error", "-show_entries",
      "stream=codec_type,codec_name,profile,pix_fmt,channels,color_transfer:stream_tags=language:stream_disposition=forced",
      "-of", "json", path)
    streams = JSON.parse(out.empty? ? "{}" : out).fetch("streams", [])
    # ffprobe 8+ reports some files' colour metadata only per frame; the
    # prober reads it there too (Media::Probe.with_frame_color).
    video = streams.find { |stream| stream["codec_type"] == "video" }
    if video && video["color_transfer"].nil?
      frame_out, = Open3.capture3(ffprobe, "-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames",
        "-show_entries", "frame=color_transfer", "-of", "json", path)
      video["color_transfer"] = JSON.parse(frame_out.empty? ? "{}" : frame_out).fetch("frames", []).first&.dig("color_transfer")
    end
    [ streams, err, status ]
  end

  it "has a manifest entry for every file, and a file for every entry" do
    # torture/ is its own corpus (bin/torture-fixtures, torture_spec).
    on_disk = Dir.children(root).reject { |name| name == "manifest.json" || File.directory?(File.join(root, name)) }.sort
    expect(on_disk).to eq(manifest.fetch("files").keys.sort)
  end

  manifest.fetch("files").each do |name, expected|
    it "#{name} — #{expected.fetch('why')}" do
      streams, err, = probe(ffprobe, File.join(root, name))

      if expected["broken"]
        expect(err).to match(/ended prematurely|invalid data|truncat/i)
        next
      end

      expect(err).to be_empty
      expect(streams.length).to eq(expected.fetch("streams").length)
      expected.fetch("streams").each_with_index do |want, i|
        got = streams.fetch(i)
        expect(got["codec_type"]).to eq(want.fetch("type")), "stream #{i} type"
        expect(got["codec_name"]).to eq(want.fetch("codec")), "stream #{i} codec"
        %w[profile pix_fmt channels color_transfer].each do |key|
          expect(got[key]).to eq(want[key]), "stream #{i} #{key}" if want.key?(key)
        end
        expect(got.dig("tags", "language")).to eq(want["language"]) if want.key?("language")
        expect(got.dig("disposition", "forced")).to eq(1) if want["forced"]
      end
    end
  end
end
