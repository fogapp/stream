# typed: false
# frozen_string_literal: true

require "rails_helper"

# What a live relay leaves on the cache (PROPOSAL §7.8): segments a killed
# run left behind are cleared, and nothing a viewer might still fetch is.
RSpec.describe Playback::LiveCache do
  let(:key) { "stream-abc" }

  around do |example|
    Dir.mktmpdir("stream-cache") do |cache|
      @cache = cache
      example.run
    end
  end

  before { stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache)) }

  def segment(name, age:)
    path = described_class.directory(key).join(name)
    File.write(path, "x")
    File.utime(Time.now - age, Time.now - age, path) # rubocop:disable Rails/TimeZone
    path
  end

  describe ".prune!" do
    before { FileUtils.mkdir_p(described_class.directory(key)) }

    it "deletes old segments the playlist no longer names, and keeps the named and the newly written" do
      File.write(described_class.playlist(key), "#EXTM3U\n#EXTINF:5.0,\nseg-10.m4s\n#EXTINF:5.0,\nseg-11.m4s\n")
      orphan = segment("seg-3.m4s", age: 600)
      named = segment("seg-10.m4s", age: 600)
      fresh = segment("seg-12.m4s", age: 2)
      init = segment("init.mp4", age: 600)

      expect(described_class.prune!(key)).to eq(1)
      expect(orphan).not_to exist
      expect([ named, fresh, init ]).to all(exist)
    end

    it "deletes nothing when the playlist can't be read or has no segments yet" do
      orphan = segment("seg-3.m4s", age: 600)
      expect(described_class.prune!(key)).to eq(0)

      File.write(described_class.playlist(key), "#EXTM3U\n")
      expect(described_class.prune!(key)).to eq(0)
      expect(orphan).to exist
    end
  end
end
