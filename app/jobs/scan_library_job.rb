# typed: strict
# frozen_string_literal: true

# Reconciles one library (or one path inside it) with the disk, then queues
# the per-file probes (PROPOSAL §5.1). One scan per library at a time.
#
# Success stamps last_scanned_at and the counts; failure records the error
# and leaves last_scanned_at alone, so a library that hasn't scanned cleanly
# in days says so (CLAUDE.md invariant 5). Only a full scan speaks for the
# library: one folder's says nothing about the rest, so it goes on the
# timeline and leaves the library's record alone.
class ScanLibraryJob < ApplicationJob
  extend T::Sig

  queue_as :scan
  limits_concurrency to: 1, key: ->(library_id, _subpath = nil) { "scan_library:#{library_id}" }, duration: 2.hours
  # A missing root is recorded on the library, not retried: the next hourly
  # scan is the retry, and it will say the same thing until someone mounts it.
  discard_on Libraries::Scanner::RootUnavailable

  sig { params(library_id: String, subpath: T.nilable(String)).void }
  def perform(library_id, subpath = nil)
    library = Library.unscoped.find_by(id: library_id)
    # A live library has no folders (PROPOSAL §7.8).
    return if library.nil? || !library.kind_enum.folders?

    library.update!(last_scan_started_at: Time.current) if subpath.nil?
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond).to_f
    counts = Libraries::Scanner.new(library, subpath: subpath).call
    if counts.unread.any?
      record_incomplete(library, counts, subpath)
    elsif subpath.nil?
      library.update!(last_scanned_at: Time.current, last_scan_error: nil, consecutive_scan_failures: 0, last_scan_counts: counts.to_h)
    end
    record_success(library, counts, subpath, started)
  rescue Libraries::Scanner::RootUnavailable => e
    if library
      record_failure(library, subpath, e.message)
      Activity.record(source: "library", event: "library.scan_failed", severity: Activity::Severity::Error,
        subject: library, household_id: library.household_id, summary: "#{library.name}: #{e.message}")
    end
    raise
  end

  sig { override.params(error: Exception).returns(T::Boolean) }
  def report_death?(error) = !error.is_a?(Libraries::Scanner::RootUnavailable)

  private

  # What it could read is done; what it couldn't is as it was. Not a clean
  # scan, so last_scanned_at stays where the last clean one left it.
  sig { params(library: Library, counts: Libraries::Scanner::Counts, subpath: T.nilable(String)).void }
  def record_incomplete(library, counts, subpath)
    unread = counts.unread.size
    message = "Couldn't read #{unread} #{unread == 1 ? 'path' : 'paths'}, starting with #{counts.unread.first}. What's there was left as it was."
    record_failure(library, subpath, message)
    Activity.record(source: "library", event: "library.scan_incomplete", severity: Activity::Severity::Warn,
      subject: library, household_id: library.household_id, summary: "#{library.name}: #{message}", payload: counts.to_h)
  end

  sig { params(library: Library, subpath: T.nilable(String), message: String).void }
  def record_failure(library, subpath, message)
    return unless subpath.nil?

    # No longer under way, whatever last_scanned_at says: that stays with the
    # last clean scan, and Library#scanning? reads the two together.
    library.update!(last_scan_error: message.truncate(500), consecutive_scan_failures: library.consecutive_scan_failures + 1,
      last_scan_started_at: nil)
  end

  sig do
    params(library: Library, counts: Libraries::Scanner::Counts, subpath: T.nilable(String), started: Float).void
  end
  def record_success(library, counts, subpath, started)
    return if counts.added.zero? && counts.changed.zero? && counts.missing.zero? && counts.purged.zero?

    parts = { "new" => counts.added, "changed" => counts.changed, "missing" => counts.missing, "removed" => counts.purged }
      .reject { |_, count| count.zero? }.map { |label, count| "#{count} #{label}" }
    Activity.record(source: "library", event: "library.scanned", subject: library, household_id: library.household_id,
      summary: "#{library.name}#{subpath ? " (#{subpath})" : ''}: #{parts.join(', ')}",
      payload: counts.to_h, duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond).to_f - started).round)
  end
end
