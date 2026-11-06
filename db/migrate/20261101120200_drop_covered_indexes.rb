# frozen_string_literal: true

# Indexes that say nothing a longer one doesn't: each is non-unique, a leading
# prefix of another full btree index on its table, and had no scans in
# production's pg_stat_user_indexes (2026-11-01). The longer index still serves
# their lookups, so this holds however young those stats were. Every title
# saved and row written paid for them.
#
# Concurrently, so no write waits on a table a scan is filling.
class DropCoveredIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = {
    airing_reminders: %w[profile_id], album_clips: %w[album_id], channels: %w[household_id library_id], clip_people: %w[clip_id],
    clips: %w[library_id], device_commands: %w[device_id], devices: %w[household_id], home_people: %w[household_id],
    job_runs: %w[household_id], libraries: %w[household_id], live_streams: %w[library_id], movies: %w[household_id library_id],
    path_mappings: %w[household_id], playabilities: %w[household_id media_file_id], playback_sessions: %w[household_id],
    playlist_items: %w[playlist_id], plex_imports: %w[household_id], plex_user_mappings: %w[plex_connection_id],
    profile_notices: %w[profile_id], profile_tags: %w[profile_id], ratings: %w[profile_id], show_preferences: %w[profile_id],
    shows: %w[household_id library_id], station_favorites: %w[profile_id], station_hides: %w[profile_id],
    stations: %w[household_id], youtube_downloads: %w[household_id]
  }.freeze

  def up
    each_index { |table, column, name| remove_index table, name: name, column: column, algorithm: :concurrently, if_exists: true }
  end

  def down
    each_index { |table, column, name| add_index table, column, name: name, algorithm: :concurrently, if_not_exists: true }
  end

  private

  def each_index
    INDEXES.each { |table, columns| columns.each { |column| yield table, column, "index_#{table}_on_#{column}" } }
  end
end
