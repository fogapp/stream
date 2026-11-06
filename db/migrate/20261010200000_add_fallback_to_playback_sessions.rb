# frozen_string_literal: true

# A play that failed carries on as another session one rung down the ladder:
# the failed one says how it failed,
# and the one after it which it came from.
class AddFallbackToPlaybackSessions < ActiveRecord::Migration[8.1]
  def change
    add_reference :playback_sessions, :fallback_from, type: :uuid, foreign_key: { to_table: :playback_sessions, on_delete: :nullify },
      index: true
    add_column :playback_sessions, :failure_class, :string
    add_column :playback_sessions, :failure_cause, :string
    add_column :playback_sessions, :failed_at, :datetime
  end
end
