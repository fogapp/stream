# typed: strict
# frozen_string_literal: true

module Transcripts
  # WebVTT cues as lines of speech (PROPOSAL §5.5): styling, speaker tags
  # and sound cues ("[music]") dropped; a rolling caption's repeats merged.
  module Vtt
    extend T::Sig

    TIMING = /\A(?<start>(?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})\s+-->\s+(?<end>(?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})/

    sig { params(text: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.parse(text)
      lines = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      text.split(/\r?\n\r?\n/).each do |block|
        rows = block.lines.map(&:strip)
        index = rows.index { |row| row.match?(TIMING) }
        next if index.nil?

        timing = T.must(rows[index]).match(TIMING)
        words = clean(rows.drop(index + 1).join(" "))
        next if words.empty?

        start = seconds(T.must(timing)[:start].to_s)
        finish = seconds(T.must(timing)[:end].to_s)
        previous = lines.last
        if previous && previous[:text] == words
          previous[:end] = finish
        else
          lines << { start: start, end: finish, text: words }
        end
      end
      lines
    end

    sig { params(text: String).returns(String) }
    def self.clean(text)
      text.gsub(/<[^>]*>/, "").gsub(/\{\\[^}]*\}/, "").gsub(/\[[^\]]*\]|\([A-Z][A-Z ]+\)/, "")
        .gsub(/&amp;/, "&").gsub(/&lt;/, "<").gsub(/&gt;/, ">").gsub(/&nbsp;/, " ")
        .sub(/\A-\s*/, "").squeeze(" ").strip
    end

    sig { params(stamp: String).returns(Float) }
    def self.seconds(stamp)
      stamp.tr(",", ".").split(":").map(&:to_f).reduce(0.0) { |total, part| (total * 60) + part }
    end
    private_class_method :clean, :seconds
  end
end
