# typed: strict
# frozen_string_literal: true

# What was said in a file (PROPOSAL §5.5), one row per file.
class Transcript < ApplicationRecord
  extend T::Sig

  class Source < T::Enum
    include ApplicationEnum
    enums do
      Subtitles = new("subtitles")
      Whisper = new("whisper")
    end
  end

  belongs_to :media_file
  has_many :transcript_lines, -> { order(:start_seconds) }, dependent: :delete_all, inverse_of: :transcript

  attribute :source, Source

  # Replaces the lines: [{ start:, end:, text: }].
  sig { params(lines: T::Array[T::Hash[Symbol, T.untyped]]).void }
  def replace_lines(lines)
    Transcript.transaction do
      transcript_lines.delete_all
      rows = lines.map do |line|
        { transcript_id: id, media_file_id: media_file_id, start_seconds: line.fetch(:start), end_seconds: line.fetch(:end),
          text: line.fetch(:text) }
      end
      rows.each_slice(1000) { |slice| TranscriptLine.insert_all!(slice) } # rubocop:disable Rails/SkipsModelValidations
      update!(line_count: rows.size)
    end
  end
end
