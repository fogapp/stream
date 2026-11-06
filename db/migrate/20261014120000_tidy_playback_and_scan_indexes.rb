# frozen_string_literal: true

# Indexes where they're read, and not where a wider one already answers.
#
# Each single-column index dropped here is the leading column of a
# composite index on the same table, which serves the same lookups; these
# are the tables written during every scan, probe and play, where an
# index is paid for on each insert. (Production, 2026-10-14: 55 such
# indexes, 6.9 MB in all — only the hot tables' are worth the change.)
#
# Added: the active sessions, by when they last reported — what the
# heavy-queue gate (every minute), the standby sweep (every 5 s) and
# Placement ask, none of them per household; and playback events by kind
# and time, which the stall check and the reliability report filter by.
class TidyPlaybackAndScanIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  REDUNDANT = {
    media_streams: :media_file_id,
    analysis_runs: :media_file_id,
    markers: :media_file_id,
    audio_fingerprints: :media_file_id,
    playback_events: :playback_session_id,
    airings: :station_block_id,
    watch_states: :profile_id
  }.freeze

  def up
    REDUNDANT.each { |table, column| remove_index table, column, algorithm: :concurrently, if_exists: true }
    remove_index :media_files, :household_id, algorithm: :concurrently, if_exists: true
    remove_index :media_files, :library_id, algorithm: :concurrently, if_exists: true
    add_index :playback_sessions, :last_seen_at, where: "state = 'active'", name: "index_playback_sessions_active_on_last_seen_at",
      algorithm: :concurrently, if_not_exists: true
    add_index :playback_events, %i[kind created_at], algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :playback_events, %i[kind created_at], algorithm: :concurrently, if_exists: true
    remove_index :playback_sessions, name: "index_playback_sessions_active_on_last_seen_at", algorithm: :concurrently, if_exists: true
    add_index :media_files, :library_id, algorithm: :concurrently, if_not_exists: true
    add_index :media_files, :household_id, algorithm: :concurrently, if_not_exists: true
    REDUNDANT.each { |table, column| add_index table, column, algorithm: :concurrently, if_not_exists: true }
  end
end
