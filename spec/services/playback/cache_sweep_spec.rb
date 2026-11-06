# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Playback::CacheSweep do
  around do |example|
    Dir.mktmpdir("stream-cache") do |cache|
      @cache = cache
      example.run
    end
  end

  before do
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    stub_const("#{described_class}::CACHE_BUDGET", 200)
    Playback::Cache::FREE.value = nil
  end

  after { Playback::Cache::FREE.value = nil }

  let(:session_id) { SecureRandom.uuid }
  let(:directory) { Playback::Cache.directory(session_id) }

  def gop(number, age:, bytes: 100)
    FileUtils.mkdir_p(directory)
    path = directory.join("gop-#{number}.m4s")
    File.write(path, "x" * bytes)
    FileUtils.touch(path, mtime: age.ago.to_time)
    path
  end

  def sweep(asked: {}) = described_class.new(running: -> { Set[session_id] }, asked: -> { asked })

  describe "with only running sessions left over budget" do
    it "takes the oldest of what they made, only until it fits" do
      oldest = gop(1, age: 40.minutes)
      older = gop(2, age: 30.minutes)
      old = gop(3, age: 20.minutes)
      newest = gop(4, age: 15.minutes)

      sweep.call

      expect([ oldest, older, old, newest ].map(&:exist?)).to eq([ false, false, true, true ])
    end

    it "leaves what's ahead of where the player last asked, however old" do
      behind = gop(1, age: 20.minutes)
      asked = gop(5, age: 40.minutes)
      ahead = gop(6, age: 40.minutes)
      after = gop(7, age: 40.minutes)

      sweep(asked: { directory.to_s => 5 }).call

      expect(behind).not_to exist
      expect([ asked, ahead, after ]).to all(exist)
    end

    it "leaves what was made lately, and what a run hasn't finished" do
      fresh = gop(1, age: 1.minute, bytes: 500)
      staged = directory.join("run-ab12/gop-2.m4s")
      FileUtils.mkdir_p(staged.dirname)
      File.write(staged, "x" * 500)
      FileUtils.touch(staged, mtime: 1.hour.ago.to_time)

      sweep.call

      expect([ fresh, staged ]).to all(exist)
    end
  end

  describe "#ensure_room!" do
    def df_says(*free)
      answers = free.map { |bytes| "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 1 1 #{bytes / 1024} 1% /\n" }
      allow(IO).to receive(:popen).with(array_including("df"), any_args) { answers.size > 1 ? answers.shift : answers.first }
    end

    it "looks at the disk again after sweeping it, rather than at what it saw before" do
      df_says(1.gigabyte, 10.gigabytes)
      expect { sweep.ensure_room! }.not_to raise_error
    end

    it "says how much is free as of now when a sweep didn't make enough room" do
      df_says(1.gigabyte, 2.gigabytes)
      expect { sweep.ensure_room! }.to raise_error("the transcoder's cache disk is full (2048 MB free)")
    end

    # Refused, the rung would be remembered as failed for this file, for a
    # disk that's about to be fine.
    it "starts the run rather than refusing it while a sweep is making the room" do
      df_says(1.gigabyte)
      swept = sweep
      swept.instance_variable_get(:@walking).lock
      expect(swept).not_to receive(:walk)
      expect { swept.ensure_room! }.not_to raise_error
    end

    it "doesn't walk the cache again for a sweep that has only just finished" do
      df_says(1.gigabyte)
      swept = sweep
      swept.call
      expect(swept).not_to receive(:walk)
      expect { swept.ensure_room! }.to raise_error(/disk is full/)
    end
  end
end
