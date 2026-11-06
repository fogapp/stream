# typed: strict
# frozen_string_literal: true

# A lesson plays taught (Playability) for the Playback page's Learned table.
module PlaybackLessonSerializer
  extend T::Sig

  sig { params(row: Playability).returns(T::Hash[Symbol, T.untyped]) }
  def self.row_json(row)
    failed = row.last_failed_at
    {
      id: row.id, media_file_id: row.media_file_id, filename: row.media_file&.filename, client_class: row.client_class,
      rung: row.rung, rung_label: Playback::Learned::LABELS.fetch(row.rung, row.rung), failures: row.failures, successes: row.successes,
      failure_class: row.last_failure_class, cause: row.last_failure_cause, last_failed_at: failed&.iso8601,
      last_succeeded_at: row.last_succeeded_at&.iso8601, active: row.failing?,
      retry_at: failed && (failed + Playability::PROBATION).iso8601
    }
  end
end
