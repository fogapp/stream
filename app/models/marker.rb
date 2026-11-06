# typed: strict
# frozen_string_literal: true

# A skippable span of one file (PROPOSAL §4.3). One per kind per file; a
# person's correction (manual) outranks a chapter, which outranks audio
# matching.
class Marker < ApplicationRecord
  extend T::Sig

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Intro = new("intro")
      Recap = new("recap")
      Credits = new("credits")
    end
  end

  class Source < T::Enum
    include ApplicationEnum
    enums do
      Chapter = new("chapter")
      Detected = new("detected")
      Manual = new("manual")
    end

    extend T::Sig

    sig { returns(Integer) }
    def rank
      case self
      when Detected then 0
      when Chapter then 1
      when Manual then 2
      else T.absurd(self)
      end
    end
  end

  belongs_to :media_file

  attribute :kind, Kind
  attribute :source, Source

  validates :end_seconds, comparison: { greater_than: :start_seconds }

  # Sets the marker unless one from a more trusted source is already there.
  sig do
    params(file: MediaFile, kind: Kind, start: Float, finish: Float, source: Source, confidence: Float)
      .returns(T.nilable(Marker))
  end
  def self.offer(file, kind, start:, finish:, source:, confidence: 1.0)
    marker = find_or_initialize_by(media_file: file, kind: kind.serialize)
    current = marker.source_enum
    return nil if marker.persisted? && current && current.rank > source.rank

    marker.update!(start_seconds: start.round(2), end_seconds: finish.round(2), source: source.serialize,
      confidence: confidence.round(3))
    marker
  end
end
