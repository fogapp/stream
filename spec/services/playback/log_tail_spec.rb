# typed: false
# frozen_string_literal: true

require "rails_helper"

# The end of a log that only grows, read from its end: what reading the
# whole of it said, without reading the whole of it.
RSpec.describe Playback::LogTail do
  around do |example|
    Dir.mktmpdir("log-tail") do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  def log(text) = @dir.join("ffmpeg.log").tap { |path| File.binwrite(path, text) }

  it "gives a long log's last lines as reading every line did" do
    path = log((1..50_000).map { |n| "frame=#{n} fps=24 q=28.0 size=#{n * 3}kB time=00:00:#{n % 60}\n" }.join + "Conversion failed!")
    expect(described_class.read(path, bytes: described_class::LINES_WINDOW, lines: 3)).to eq(File.readlines(path).last(3).join)
    expect(described_class.read(path, bytes: 64)).to eq(File.binread(path)[-64..])
  end

  it "starts no earlier than asked, replaces bytes that aren't text, and is empty for a file that isn't there" do
    path = log("before\nthis run\n\xFF\xFEsaid\n".b)
    expect(described_class.read(path, bytes: 1000, from: 7)).to eq("this run\n��said\n")
    expect(described_class.read(path, bytes: 5, from: 0)).to eq("said\n")
    expect(described_class.read(path, bytes: 1000, lines: 1)).to eq("��said\n")
    expect(described_class.read(@dir.join("missing.log"), bytes: 10)).to eq("")
    expect(described_class.read(log(""), bytes: 10, lines: 3)).to eq("")
  end
end
