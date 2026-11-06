# typed: strict
# frozen_string_literal: true

# One library's quick look for what's arrived since it last looked, queuing a
# targeted scan of each folder that changed (PROPOSAL §5.1).
class DetectLibraryChangeJob < ApplicationJob
  extend T::Sig

  queue_as :default
  # A slow share can take longer than the interval to list; a look that
  # finds one still going is dropped, not queued behind it.
  limits_concurrency to: 1, key: ->(library_id) { "detect_library_change:#{library_id}" }, duration: 15.minutes,
    on_conflict: :discard

  sig { params(library_id: String).void }
  def perform(library_id)
    library = Library.unscoped.find_by(id: library_id)
    # A live library has no folders (PROPOSAL §7.8).
    return if library.nil? || !library.kind_enum.folders?

    Libraries::ChangeDetector.new(library).call
  end
end
