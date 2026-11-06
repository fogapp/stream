# typed: strict
# frozen_string_literal: true

module Channels
  # Chapters from a description (PROPOSAL §5.5): YouTube's convention of
  # lines that start with a timestamp, the first at 0:00.
  module Timestamps
    extend T::Sig

    LINE = /\A\s*[(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[)\]]?\s*[-–—:.|]?\s*(.+?)\s*\z/

    sig { params(text: String).returns(Integer) }
    def self.seconds(text)
      text.split(":").map(&:to_i).reduce(0) { |total, part| (total * 60) + part }
    end

    sig { params(description: T.nilable(String), duration: T.nilable(Float)).returns(T::Array[T::Hash[String, T.untyped]]) }
    def self.chapters(description, duration)
      found = description.to_s.lines.filter_map do |line|
        match = line.match(LINE)
        match && { "start" => seconds(T.must(match[1])).to_f, "title" => T.must(match[2]) }
      end
      # Three or more, starting at zero and going forwards: otherwise it's
      # a stray time in the text, not a chapter list.
      starts = found.map { |chapter| chapter["start"] }
      return [] if found.size < 3 || starts.first != 0.0 || starts != starts.sort

      found.each_with_index.map do |chapter, index|
        chapter.merge("end" => found[index + 1]&.fetch("start") || duration)
      end
    end
  end
end
