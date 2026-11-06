# typed: strict
# frozen_string_literal: true

# A file's intro, recap and credits (PROPOSAL §8.2), in playing order: what
# the player skips, online or offline.
module MarkerSerializer
  extend T::Sig

  # `detail` adds where each came from, for the file page.
  sig { params(file: T.nilable(MediaFile), detail: T::Boolean).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.list(file, detail: false)
    return [] if file.nil?

    file.markers.order(:start_seconds).map do |marker|
      json = { kind: marker.kind_enum, start: marker.start_seconds, end: marker.end_seconds }
      detail ? json.merge(source: marker.source_enum, confidence: marker.confidence) : json
    end
  end
end
