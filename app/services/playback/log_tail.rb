# typed: strict
# frozen_string_literal: true

module Playback
  # The end of a file that only grows (an ffmpeg log, its -progress file, a
  # run's playlist), read from the end: never the whole of it, however long
  # a run has been talking.
  module LogTail
    extend T::Sig

    # Enough of a log's end to hold its last few lines: ffmpeg's are short.
    LINES_WINDOW = T.let(64 * 1024, Integer)

    # The last `bytes` of the file (none before `from`), as text, invalid
    # bytes replaced; with `lines`, only its last that many lines of those.
    # Empty when there's no such file, or it can't be read.
    sig { params(path: T.any(String, Pathname), bytes: Integer, lines: T.nilable(Integer), from: Integer).returns(String) }
    def self.read(path, bytes:, lines: nil, from: 0)
      text = File.open(path.to_s, "rb") do |file|
        file.seek([ file.size - bytes, from, 0 ].max)
        file.read.to_s.force_encoding(Encoding::UTF_8).scrub
      end
      lines ? text.lines.last(lines).join : text
    rescue SystemCallError
      ""
    end
  end
end
