# typed: strict
# frozen_string_literal: true

module LibrarySerializer
  extend T::Sig

  # File counts per state for every library in one grouped query.
  sig { params(libraries: T::Array[Library]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.list_json(libraries)
    counts = MediaFile.where(library_id: libraries.map(&:id)).group(:library_id, :state).count
    libraries.map do |library|
      by_state = MediaFile::State.values.to_h do |state|
        [ state.serialize, counts.fetch([ library.id, state.serialize ], 0) ]
      end
      library_json(library).merge(file_counts: by_state)
    end
  end

  sig { params(library: Library).returns(T::Hash[Symbol, T.untyped]) }
  def self.library_json(library)
    {
      id: library.id, name: library.name, kind: library.kind_enum, roots: library.roots,
      metadata_language: library.metadata_language,
      scanning: library.scanning?, last_scanned_at: library.last_scanned_at,
      last_scan_started_at: library.last_scan_started_at, last_scan_error: library.last_scan_error,
      consecutive_scan_failures: library.consecutive_scan_failures, last_scan_counts: library.last_scan_counts,
      created_at: library.created_at
    }
  end
end
