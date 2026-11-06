# typed: strict
# frozen_string_literal: true

module Media
  # The OpenSubtitles movie hash: the file size plus the 64-bit little-endian
  # word sums of the first and last 64 KiB, as 16 hex digits. Two 64 KiB
  # reads — cheap over a NAS — and stable across renames and moves, which is
  # what lets watch state follow a file (PROPOSAL §4.1). OpenSubtitles keys
  # its search on the same value, so Phase 4's subtitle fetch gets it free.
  module Fingerprint
    extend T::Sig

    CHUNK = 65_536
    MASK = 0xFFFF_FFFF_FFFF_FFFF

    sig { params(path: String).returns(String) }
    def self.compute(path)
      File.open(path, "rb") do |file|
        size = file.size
        hash = size
        hash = add_words(hash, file.read(CHUNK).to_s)
        file.seek([ size - CHUNK, 0 ].max)
        hash = add_words(hash, file.read(CHUNK).to_s)
        format("%016x", hash)
      end
    end

    sig { params(hash: Integer, bytes: String).returns(Integer) }
    def self.add_words(hash, bytes)
      # A file shorter than a word leaves a tail too short to unpack; pad it
      # so tiny files still hash deterministically.
      padded = bytes.ljust((bytes.bytesize + 7) / 8 * 8, "\0")
      padded.unpack("Q<*").each { |word| hash = (hash + word.to_i) & MASK }
      hash
    end
    private_class_method :add_words
  end
end
