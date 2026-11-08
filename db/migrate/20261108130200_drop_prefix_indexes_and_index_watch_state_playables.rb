# frozen_string_literal: true

# Indexes that say nothing a longer one doesn't: each is non-unique and the
# leading column of another full (not partial) btree index on its table,
# which serves its lookups, foreign keys' included. Every write to these
# tables paid for them.
#
# And one that was missing: what a title has been watched as, by every
# profile (WatchState by playable), was a scan; the uniqueness index leads
# with the profile.
#
# Concurrently, so no write waits on a table a scan is filling.
class DropPrefixIndexesAndIndexWatchStatePlayables < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # name => [table, columns], each covered by the index noted.
  INDEXES = {
    "index_editions_on_media_file_id" => [ :editions, %w[media_file_id] ], # index_editions_uniqueness
    "index_episodes_on_show_id" => [ :episodes, %w[show_id] ], # (show_id, air_date)
    "index_credits_on_creditable" => [ :credits, %w[creditable_type creditable_id] ], # index_credits_listing
    "index_videos_on_channel_id" => [ :videos, %w[channel_id] ], # (channel_id, identity)
    "index_seasons_on_show_id" => [ :seasons, %w[show_id] ], # (show_id, season_number)
    "index_collection_items_on_collection_id" => [ :collection_items, %w[collection_id] ], # index_collection_items_uniqueness
    "index_collection_parts_on_collection_id" => [ :collection_parts, %w[collection_id] ], # (collection_id, tmdb_id)
    "index_sponsor_segments_on_video_id" => [ :sponsor_segments, %w[video_id] ], # (video_id, uuid)
    "index_youtube_downloads_on_channel_id" => [ :youtube_downloads, %w[channel_id] ], # (channel_id, youtube_id)
    "index_profiles_on_household_id" => [ :profiles, %w[household_id] ], # (household_id, name)
    "index_channel_subscriptions_on_profile_id" => [ :channel_subscriptions, %w[profile_id] ], # (profile_id, channel_id)
    "index_notifications_on_user_id" => [ :notifications, %w[user_id] ], # (user_id, dedupe_key)
    "index_activity_entries_on_household_id" => [ :activity_entries, %w[household_id] ], # (household_id, created_at)
    "index_optimized_versions_on_state" => [ :optimized_versions, %w[state] ], # (state, needed_at)
    "index_transcode_runs_on_transcode_node_id" => [ :transcode_runs, %w[transcode_node_id] ] # (transcode_node_id, state)
  }.freeze

  PLAYABLES = "index_watch_states_on_playable_type_and_playable_id"

  def up
    INDEXES.each { |name, (table, columns)| remove_index table, columns, name: name, algorithm: :concurrently, if_exists: true }
    add_index :watch_states, %i[playable_type playable_id], name: PLAYABLES, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :watch_states, name: PLAYABLES, algorithm: :concurrently, if_exists: true
    INDEXES.each { |name, (table, columns)| add_index table, columns, name: name, algorithm: :concurrently, if_not_exists: true }
  end
end
