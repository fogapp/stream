# typed: false
# frozen_string_literal: true

require "rails_helper"

# A YouTube live stream's playlists (PROPOSAL §7.8), with yt-dlp stubbed:
# asked for by a URL rebuilt from the id, kept until shortly before they
# expire, and what YouTube says turned into words.
RSpec.describe LiveStreams::YoutubeSource do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { Household.create!(name: "Family") }
  let(:library) { Library.create!(household: household, name: "Live", kind: "live") }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Lofi Girl", kind: "youtube",
      url: "https://youtu.be/rFZHOHl-L8A?si=shared")
  end
  let(:expire) { 6.hours.from_now.to_i }
  let(:video) { "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/#{expire}/ei/x/itag/270/playlist/index.m3u8" }
  let(:audio) { "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/#{expire}/ei/x/itag/234/playlist/index.m3u8" }
  let(:seen) { [] }

  def answer(stdout: "", stderr: "", status: 0)
    allow(ToolRunner).to receive(:run) do |argv, **|
      seen << argv
      ToolRunner::Result.new(status: status, stdout: stdout, stderr: stderr)
    end
  end

  around do |example|
    cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = cache
  end

  it "asks yt-dlp for the live picture and sound by the canonical link, and keeps them until shortly before they expire" do
    answer(stdout: "#{video}\n#{audio}\n")

    found = described_class.resolve(stream)
    expect(found).to have_attributes(video: video, audio: audio)
    argv = seen.sole
    expect(argv.last(2)).to eq([ "--", "https://www.youtube.com/watch?v=rFZHOHl-L8A" ])
    expect(argv.each_cons(2).to_a).to include([ "--match-filter", "is_live" ], [ "--format", Youtube::YtDlp::LIVE_FORMAT ])

    described_class.resolve(stream)
    expect(seen.size).to eq(1)

    travel 5.hours + 31.minutes do
      described_class.resolve(stream)
    end
    expect(seen.size).to eq(2)
  end

  it "asks again once forgotten" do
    answer(stdout: "#{video}\n")
    expect(described_class.resolve(stream).audio).to be_nil
    described_class.forget(stream)
    described_class.resolve(stream)
    expect(seen.size).to eq(2)
  end

  it "says when the stream isn't live, or what YouTube said instead" do
    answer(stdout: "")
    expect { described_class.resolve(stream) }.to raise_error(LiveStreams::Prober::Failure, "Lofi Girl isn't live on YouTube right now")

    answer(stderr: "ERROR: [youtube:tab] @LofiGirl: The channel is not currently live\n", status: 1)
    expect { described_class.resolve(stream) }.to raise_error(LiveStreams::Prober::Failure, "Lofi Girl isn't live on YouTube right now")

    answer(stderr: "ERROR: [youtube] rFZHOHl-L8A: Video unavailable. This video has been removed\n", status: 1)
    expect { described_class.resolve(stream) }.to raise_error(LiveStreams::Prober::Failure, "YouTube says that video isn't available")
  end
end
