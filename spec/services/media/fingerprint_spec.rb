# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Media::Fingerprint do
  def write(bytes)
    file = Tempfile.new("fingerprint", binmode: true)
    file.write(bytes)
    file.flush
    file
  end

  it "is the size plus the word sums of the first and last 64 KiB" do
    # 200 KiB of one repeated word: the head and tail chunks each sum to
    # 8192 copies of it; the middle is never read.
    word = 0x0102030405060708
    file = write([ word ].pack("Q<") * (200 * 1024 / 8))
    expected = (file.size + (2 * 8192 * word)) & described_class::MASK
    expect(described_class.compute(file.path)).to eq(format("%016x", expected))
  end

  it "is the same for a copy under another name, and different when the content changes" do
    original = write(Random.new(1).bytes(300_000))
    copy = write(File.binread(original.path))
    changed = write(File.binread(original.path).tap { |bytes| bytes.setbyte(10, (bytes.getbyte(10) + 1) % 256) })

    expect(described_class.compute(copy.path)).to eq(described_class.compute(original.path))
    expect(described_class.compute(changed.path)).not_to eq(described_class.compute(original.path))
  end

  it "handles files smaller than a chunk, including ones not a multiple of eight bytes" do
    expect(described_class.compute(write("abc").path)).to match(/\A\h{16}\z/)
  end
end
