# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_08_130200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"
  enable_extension "unaccent"
  enable_extension "vector"

  create_table "activity_entries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "event", null: false
    t.uuid "household_id"
    t.jsonb "payload", default: {}, null: false
    t.string "severity", default: "info", null: false
    t.string "source", null: false
    t.uuid "subject_id"
    t.string "subject_type"
    t.string "summary", null: false
    t.uuid "trace_id"
    t.index ["created_at"], name: "index_activity_entries_on_created_at"
    t.index ["household_id", "created_at"], name: "index_activity_entries_on_household_id_and_created_at"
    t.index ["severity", "created_at"], name: "index_activity_entries_on_severity_and_created_at"
    t.index ["subject_type", "subject_id"], name: "index_activity_entries_on_subject"
    t.index ["trace_id"], name: "index_activity_entries_on_trace_id"
  end

  create_table "airing_reminders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "airing_id", null: false
    t.datetime "created_at", null: false
    t.datetime "notified_at"
    t.uuid "profile_id", null: false
    t.uuid "user_id", null: false
    t.index ["airing_id"], name: "index_airing_reminders_on_airing_id"
    t.index ["profile_id", "airing_id"], name: "index_airing_reminders_on_profile_id_and_airing_id", unique: true
    t.index ["user_id"], name: "index_airing_reminders_on_user_id"
  end

  create_table "airings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "ends_at", null: false
    t.boolean "filler", default: false, null: false
    t.uuid "household_id", null: false
    t.float "media_end"
    t.uuid "media_file_id"
    t.float "media_start", default: 0.0, null: false
    t.integer "mlb_game_pk"
    t.uuid "playable_id", null: false
    t.string "playable_type", null: false
    t.string "program_subtitle"
    t.string "program_title"
    t.string "reason", null: false
    t.string "series_key", null: false
    t.datetime "starts_at", null: false
    t.uuid "station_block_id"
    t.uuid "station_id", null: false
    t.index ["household_id"], name: "index_airings_on_household_id"
    t.index ["media_file_id"], name: "index_airings_on_media_file_id"
    t.index ["playable_type", "playable_id"], name: "index_airings_on_playable"
    t.index ["station_block_id", "series_key", "starts_at"], name: "index_airings_on_station_block_id_and_series_key_and_starts_at"
    t.index ["station_id", "ends_at"], name: "index_airings_on_station_id_and_ends_at"
    t.index ["station_id", "starts_at"], name: "index_airings_on_station_id_and_starts_at", unique: true
  end

  create_table "album_clips", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "album_id", null: false
    t.uuid "clip_id", null: false
    t.index ["album_id", "clip_id"], name: "index_album_clips_on_album_id_and_clip_id", unique: true
    t.index ["clip_id"], name: "index_album_clips_on_clip_id"
  end

  create_table "albums", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "household_id", null: false
    t.string "immich_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "immich_id"], name: "index_albums_on_household_id_and_immich_id", unique: true, where: "(immich_id IS NOT NULL)"
    t.index ["household_id"], name: "index_albums_on_household_id"
  end

  create_table "analysis_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "error"
    t.datetime "finished_at"
    t.uuid "live_stream_id"
    t.uuid "media_file_id"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.string "step", null: false
    t.string "tool_version"
    t.datetime "updated_at", null: false
    t.index ["live_stream_id", "step"], name: "index_analysis_runs_on_live_stream_id_and_step", unique: true, where: "(live_stream_id IS NOT NULL)"
    t.index ["media_file_id", "step"], name: "index_analysis_runs_on_media_file_id_and_step", unique: true
    t.index ["step", "status"], name: "index_analysis_runs_on_step_and_status"
    t.check_constraint "num_nonnulls(media_file_id, live_stream_id) = 1", name: "analysis_runs_one_owner"
  end

  create_table "api_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device"
    t.datetime "expires_at"
    t.string "handoff_digest"
    t.datetime "handoff_expires_at"
    t.datetime "last_used_at"
    t.string "oidc_sid"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["handoff_digest"], name: "index_api_sessions_on_handoff_digest", unique: true
    t.index ["oidc_sid"], name: "index_api_sessions_on_oidc_sid"
    t.index ["token"], name: "index_api_sessions_on_token", unique: true
    t.index ["user_id"], name: "index_api_sessions_on_user_id"
  end

  create_table "api_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "prefix", null: false
    t.string "scope", default: "full", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "app_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "fetch_trailers", default: true, null: false
    t.datetime "fog_attested_at"
    t.integer "max_video_transcodes"
    t.string "ntfy_url"
    t.boolean "optimize_automatically", default: true, null: false
    t.integer "optimize_budget_gb", default: 200, null: false
    t.integer "optimize_max_height", default: 1080, null: false
    t.boolean "optimize_paused", default: false, null: false
    t.integer "optimize_quiet_end_hour", default: 7, null: false
    t.integer "optimize_quiet_start_hour", default: 1, null: false
    t.string "time_zone"
    t.datetime "updated_at", null: false
    t.string "webhook_url"
    t.boolean "youtube_end_screen", default: true, null: false
    t.index "(true)", name: "index_app_settings_singleton", unique: true
  end

  create_table "arr_webhooks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "last_event"
    t.string "last_outcome"
    t.datetime "last_received_at"
    t.string "last_source"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_arr_webhooks_on_household_id", unique: true
    t.index ["token"], name: "index_arr_webhooks_on_token", unique: true
  end

  create_table "artworks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "height"
    t.string "kind", null: false
    t.string "last_error"
    t.uuid "owner_id", null: false
    t.string "owner_type", null: false
    t.text "placeholder"
    t.datetime "rendered_at"
    t.integer "rendered_widths", default: [], null: false, array: true
    t.string "source", null: false
    t.string "source_ref", null: false
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 0, null: false
    t.integer "width"
    t.index ["owner_type", "owner_id", "kind"], name: "index_artworks_on_owner_type_and_owner_id_and_kind", unique: true
    t.index ["state", "updated_at"], name: "index_artworks_on_state_and_updated_at"
  end

  create_table "audio_fingerprints", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "media_file_id", null: false
    t.float "offset_seconds", null: false
    t.integer "points", default: [], null: false, array: true
    t.string "segment", null: false
    t.datetime "updated_at", null: false
    t.index ["media_file_id", "segment"], name: "index_audio_fingerprints_on_media_file_id_and_segment", unique: true
  end

  create_table "channel_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.datetime "created_at", null: false
    t.uuid "profile_id", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_channel_subscriptions_on_channel_id"
    t.index ["profile_id", "channel_id"], name: "index_channel_subscriptions_on_profile_id_and_channel_id", unique: true
  end

  create_table "channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "avatar_url"
    t.string "backfill", default: "recent", null: false
    t.integer "backfill_count", default: 30, null: false
    t.date "backfill_since"
    t.string "banner_url"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "folder", null: false
    t.string "handle"
    t.uuid "household_id", null: false
    t.integer "keep_last"
    t.string "last_poll_error"
    t.datetime "last_polled_at"
    t.uuid "library_id", null: false
    t.string "locked_fields", default: [], null: false, array: true
    t.integer "max_height", default: 1080, null: false
    t.integer "poll_every_hours", default: 1, null: false
    t.boolean "skip_live", default: true, null: false
    t.boolean "skip_shorts", default: true, null: false
    t.string "sort_title", null: false
    t.string "title", null: false
    t.string "title_filter"
    t.boolean "tracked", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.string "youtube_id"
    t.index ["household_id", "youtube_id"], name: "index_channels_on_household_id_and_youtube_id"
    t.index ["library_id", "folder"], name: "index_channels_on_library_id_and_folder", unique: true
  end

  create_table "clip_people", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "clip_id", null: false
    t.uuid "home_person_id", null: false
    t.index ["clip_id", "home_person_id"], name: "index_clip_people_on_clip_id_and_home_person_id", unique: true
    t.index ["home_person_id"], name: "index_clip_people_on_home_person_id"
  end

  create_table "clips", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.boolean "captured_floating", default: false, null: false
    t.string "captured_source", null: false
    t.string "city"
    t.string "country"
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "favorite", default: false, null: false
    t.uuid "household_id", null: false
    t.string "immich_id"
    t.float "latitude"
    t.uuid "library_id", null: false
    t.string "locked_fields", default: [], null: false, array: true
    t.float "longitude"
    t.string "sort_title", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "immich_id"], name: "index_clips_on_household_id_and_immich_id", unique: true, where: "(immich_id IS NOT NULL)"
    t.index ["household_id"], name: "index_clips_on_household_id"
    t.index ["library_id", "captured_at"], name: "index_clips_on_library_id_and_captured_at"
  end

  create_table "collection_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "collection_id", null: false
    t.datetime "created_at", null: false
    t.uuid "item_id", null: false
    t.string "item_type", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["collection_id", "item_type", "item_id"], name: "index_collection_items_uniqueness", unique: true
    t.index ["item_type", "item_id"], name: "index_collection_items_on_item"
  end

  create_table "collection_parts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "collection_id", null: false
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.text "overview"
    t.integer "position", default: 0, null: false
    t.string "poster_path"
    t.date "release_date"
    t.string "title", null: false
    t.integer "tmdb_id", null: false
    t.datetime "updated_at", null: false
    t.index ["collection_id", "tmdb_id"], name: "index_collection_parts_on_collection_id_and_tmdb_id", unique: true
    t.index ["household_id"], name: "index_collection_parts_on_household_id"
  end

  create_table "collections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "backdrop_path"
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "kind", null: false
    t.uuid "library_id"
    t.string "locked_fields", default: [], null: false, array: true
    t.datetime "metadata_refreshed_at"
    t.text "overview"
    t.string "plex_key"
    t.string "poster_path"
    t.jsonb "rules", default: {}, null: false
    t.string "sort_title", null: false
    t.string "title", null: false
    t.integer "tmdb_id"
    t.datetime "updated_at", null: false
    t.index ["household_id", "plex_key"], name: "index_collections_on_household_id_and_plex_key", unique: true, where: "(plex_key IS NOT NULL)"
    t.index ["household_id", "tmdb_id"], name: "index_collections_on_household_id_and_tmdb_id", unique: true, where: "(tmdb_id IS NOT NULL)"
    t.index ["household_id"], name: "index_collections_on_household_id"
    t.index ["library_id"], name: "index_collections_on_library_id"
  end

  create_table "credits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "character"
    t.datetime "created_at", null: false
    t.uuid "creditable_id", null: false
    t.string "creditable_type", null: false
    t.string "job"
    t.integer "order", default: 0, null: false
    t.uuid "person_id", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["creditable_type", "creditable_id", "role", "order"], name: "index_credits_listing"
    t.index ["person_id"], name: "index_credits_on_person_id"
  end

  create_table "device_commands", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.uuid "device_id", null: false
    t.datetime "expires_at", null: false
    t.uuid "household_id", null: false
    t.string "kind", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["device_id", "delivered_at"], name: "index_device_commands_on_device_id_and_delivered_at"
    t.index ["household_id"], name: "index_device_commands_on_household_id"
    t.index ["user_id"], name: "index_device_commands_on_user_id"
  end

  create_table "device_pairings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "device_label"
    t.datetime "expires_at", null: false
    t.uuid "household_id"
    t.string "poll_token", null: false
    t.text "session_token"
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["code"], name: "index_device_pairings_on_code", unique: true, where: "((state)::text = 'pending'::text)"
    t.index ["household_id"], name: "index_device_pairings_on_household_id"
    t.index ["poll_token"], name: "index_device_pairings_on_poll_token", unique: true
    t.index ["user_id"], name: "index_device_pairings_on_user_id"
  end

  create_table "devices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "capabilities", default: {}, null: false
    t.string "client_key", null: false
    t.datetime "created_at", null: false
    t.uuid "default_profile_id"
    t.uuid "household_id", null: false
    t.string "label"
    t.datetime "last_seen_at", null: false
    t.string "name", null: false
    t.boolean "remote_control", default: false, null: false
    t.datetime "remote_seen_at"
    t.datetime "updated_at", null: false
    t.index ["default_profile_id"], name: "index_devices_on_default_profile_id"
    t.index ["household_id", "client_key"], name: "index_devices_on_household_id_and_client_key", unique: true
  end

  create_table "editions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "media_file_id", null: false
    t.string "name"
    t.uuid "playable_id", null: false
    t.string "playable_type", null: false
    t.datetime "updated_at", null: false
    t.index ["media_file_id", "playable_type", "playable_id"], name: "index_editions_uniqueness", unique: true
    t.index ["playable_type", "playable_id"], name: "index_editions_on_playable"
  end

  create_table "episodes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.date "air_date"
    t.datetime "created_at", null: false
    t.integer "episode_number"
    t.string "locked_fields", default: [], null: false, array: true
    t.text "overview"
    t.integer "runtime_minutes"
    t.uuid "season_id", null: false
    t.integer "season_number", null: false
    t.uuid "show_id", null: false
    t.string "still_path"
    t.string "title"
    t.integer "tmdb_id"
    t.datetime "updated_at", null: false
    t.float "vote_average"
    t.index ["season_id"], name: "index_episodes_on_season_id"
    t.index ["show_id", "air_date"], name: "index_episodes_on_show_id_and_air_date"
    t.index ["show_id", "season_number", "episode_number"], name: "index_episodes_on_show_id_and_season_number_and_episode_number", unique: true, where: "(episode_number IS NOT NULL)"
  end

  create_table "extras", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "kind", null: false
    t.uuid "media_file_id", null: false
    t.uuid "owner_id"
    t.string "owner_type"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_extras_on_household_id"
    t.index ["media_file_id"], name: "index_extras_on_media_file_id", unique: true
    t.index ["owner_type", "owner_id"], name: "index_extras_on_owner"
  end

  create_table "fog_integrations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "api_token_id"
    t.string "consumer", null: false
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "offer", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token_id"], name: "index_fog_integrations_on_api_token_id"
    t.index ["household_id"], name: "index_fog_integrations_on_household_id"
  end

  create_table "folder_listings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "entries", default: {}, null: false
    t.uuid "household_id", null: false
    t.uuid "library_id", null: false
    t.string "root", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_folder_listings_on_household_id"
    t.index ["library_id", "root"], name: "index_folder_listings_on_library_id_and_root", unique: true
  end

  create_table "home_people", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "immich_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "immich_id"], name: "index_home_people_on_household_id_and_immich_id", unique: true
  end

  create_table "households", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "identities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "issuer", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["issuer", "subject"], name: "index_identities_on_issuer_and_subject", unique: true
    t.index ["subject"], name: "index_identities_on_subject"
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "immich_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_key", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "household_id", null: false
    t.string "immich_path_prefix"
    t.jsonb "last_sync_counts", default: {}, null: false
    t.string "last_sync_error"
    t.datetime "last_synced_at"
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.string "local_path_prefix"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["household_id"], name: "index_immich_settings_on_household_id", unique: true
  end

  create_table "invite_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.datetime "expires_at", null: false
    t.uuid "household_id", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.index ["code"], name: "index_invite_codes_on_code", unique: true
    t.index ["created_by_id"], name: "index_invite_codes_on_created_by_id"
    t.index ["household_id"], name: "index_invite_codes_on_household_id"
  end

  create_table "job_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "finished_at"
    t.uuid "household_id"
    t.string "job_key", null: false
    t.string "message"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.string "trigger", default: "system", null: false
    t.datetime "updated_at", null: false
    t.index ["finished_at"], name: "index_job_runs_on_finished_at", where: "(finished_at IS NOT NULL)"
    t.index ["household_id", "job_key", "created_at"], name: "index_job_runs_on_household_id_and_job_key_and_created_at"
    t.index ["job_key", "created_at"], name: "index_job_runs_on_job_key_and_created_at"
  end

  create_table "libraries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "consecutive_scan_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "download_root"
    t.uuid "household_id", null: false
    t.string "kind", null: false
    t.jsonb "last_scan_counts", default: {}, null: false
    t.string "last_scan_error"
    t.datetime "last_scan_started_at"
    t.datetime "last_scanned_at"
    t.string "metadata_language", default: "en", null: false
    t.string "name", null: false
    t.string "roots", default: [], null: false, array: true
    t.boolean "sponsorblock", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "name"], name: "index_libraries_on_household_id_and_name", unique: true
  end

  create_table "live_streams", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "consecutive_failures", default: 0, null: false
    t.string "container"
    t.string "content_rating"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "feed"
    t.uuid "household_id", null: false
    t.boolean "keep_connected", default: false, null: false
    t.string "kind", null: false
    t.string "last_error"
    t.datetime "last_error_at"
    t.datetime "last_seen_at"
    t.uuid "library_id"
    t.integer "mlb_team_id"
    t.string "name", null: false
    t.datetime "probed_at"
    t.integer "rating_age"
    t.string "sort_title", null: false
    t.string "status", default: "online", null: false
    t.datetime "still_at"
    t.boolean "trust_certificate", default: false, null: false
    t.datetime "updated_at", null: false
    t.text "url", null: false
    t.index ["household_id", "mlb_team_id"], name: "index_live_streams_on_household_id_and_mlb_team_id", unique: true, where: "(mlb_team_id IS NOT NULL)"
    t.index ["household_id"], name: "index_live_streams_on_household_id"
    t.index ["library_id", "sort_title"], name: "index_live_streams_on_library_id_and_sort_title"
  end

  create_table "markers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.float "confidence", default: 1.0, null: false
    t.datetime "created_at", null: false
    t.float "end_seconds", null: false
    t.string "kind", null: false
    t.uuid "media_file_id", null: false
    t.string "source", null: false
    t.float "start_seconds", null: false
    t.datetime "updated_at", null: false
    t.index ["media_file_id", "kind"], name: "index_markers_on_media_file_id_and_kind", unique: true
  end

  create_table "media_files", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "bit_rate"
    t.jsonb "chapters", default: [], null: false
    t.string "container"
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.string "fingerprint"
    t.uuid "household_id", null: false
    t.integer "keyframes", array: true
    t.string "keyframes_source"
    t.string "last_error"
    t.uuid "library_id", null: false
    t.float "loudness_lufs"
    t.datetime "missing_since"
    t.datetime "mtime", null: false
    t.string "path", null: false
    t.jsonb "probe", default: {}, null: false
    t.datetime "probed_at"
    t.jsonb "sidecar_subtitles"
    t.bigint "size", null: false
    t.float "start_time"
    t.string "state", default: "discovered", null: false
    t.float "true_peak_dbfs"
    t.datetime "updated_at", null: false
    t.index ["household_id", "fingerprint"], name: "index_media_files_on_household_id_and_fingerprint"
    t.index ["household_id", "path"], name: "index_media_files_on_household_id_and_path", unique: true
    t.index ["household_id", "state", "id"], name: "index_media_files_on_household_id_and_state_and_id"
    t.index ["library_id", "state"], name: "index_media_files_on_library_id_and_state"
  end

  create_table "media_streams", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "bit_depth"
    t.bigint "bit_rate"
    t.string "channel_layout"
    t.integer "channels"
    t.string "chroma"
    t.string "codec"
    t.string "codec_tag"
    t.string "color_primaries"
    t.string "color_transfer"
    t.boolean "comment", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "default", default: false, null: false
    t.integer "dolby_vision_profile"
    t.string "field_order"
    t.boolean "forced", default: false, null: false
    t.float "frame_rate"
    t.integer "has_b_frames"
    t.string "hdr_format"
    t.boolean "hearing_impaired", default: false, null: false
    t.integer "height"
    t.integer "index", null: false
    t.string "kind", null: false
    t.string "language"
    t.integer "level"
    t.uuid "live_stream_id"
    t.uuid "media_file_id"
    t.string "pixel_format"
    t.string "profile"
    t.integer "refs"
    t.integer "rotation"
    t.string "sample_aspect_ratio"
    t.integer "sample_rate"
    t.float "start_time"
    t.string "title"
    t.datetime "updated_at", null: false
    t.boolean "visual_impaired", default: false, null: false
    t.integer "width"
    t.integer "dolby_vision_compatibility"
    t.index ["live_stream_id", "index"], name: "index_media_streams_on_live_stream_id_and_index", unique: true, where: "(live_stream_id IS NOT NULL)"
    t.index ["media_file_id", "index"], name: "index_media_streams_on_media_file_id_and_index", unique: true
    t.check_constraint "num_nonnulls(media_file_id, live_stream_id) = 1", name: "media_streams_one_owner"
  end

  create_table "mlb_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.text "password", null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["household_id"], name: "index_mlb_settings_on_household_id", unique: true
  end

  create_table "movies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "backdrop_path"
    t.string "content_rating"
    t.datetime "created_at", null: false
    t.datetime "embedded_at"
    t.vector "embedding", limit: 512
    t.string "genres", default: [], null: false, array: true
    t.uuid "household_id", null: false
    t.string "imdb_id"
    t.string "keywords", default: [], null: false, array: true
    t.uuid "library_id", null: false
    t.string "locked_fields", default: [], null: false, array: true
    t.string "logo_path"
    t.jsonb "match_candidates", default: [], null: false
    t.jsonb "match_reasons", default: {}, null: false
    t.float "match_score"
    t.string "match_state", default: "unmatched", null: false
    t.datetime "metadata_refreshed_at"
    t.string "original_title"
    t.text "overview"
    t.string "poster_path"
    t.integer "rating_age"
    t.date "release_date"
    t.integer "runtime_minutes"
    t.string "sort_title", null: false
    t.string "studios", default: [], null: false, array: true
    t.string "tagline"
    t.string "title", null: false
    t.integer "tmdb_collection_id"
    t.string "tmdb_collection_name"
    t.integer "tmdb_id"
    t.datetime "trailer_checked_at"
    t.datetime "updated_at", null: false
    t.float "vote_average"
    t.integer "year"
    t.string "normalized_title"
    t.index ["embedding"], name: "index_movies_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["household_id", "imdb_id"], name: "index_movies_on_household_id_and_imdb_id"
    t.index ["household_id", "tmdb_id"], name: "index_movies_on_household_id_and_tmdb_id"
    t.index ["keywords"], name: "index_movies_on_keywords", using: :gin
    t.index ["library_id", "match_state"], name: "index_movies_on_library_id_and_match_state"
    t.index ["library_id", "normalized_title"], name: "index_movies_on_library_id_and_normalized_title"
    t.index ["library_id", "tmdb_id"], name: "index_movies_on_library_id_and_tmdb_id", unique: true, where: "(tmdb_id IS NOT NULL)"
    t.index ["sort_title"], name: "index_movies_on_sort_title"
    t.index ["studios"], name: "index_movies_on_studios", using: :gin
  end

  create_table "nba_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_nba_settings_on_household_id", unique: true
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "dedupe_key", null: false
    t.uuid "household_id", null: false
    t.string "icon"
    t.string "kind", null: false
    t.string "path"
    t.datetime "read_at"
    t.string "title", null: false
    t.uuid "user_id", null: false
    t.index ["created_at"], name: "index_notifications_read_on_created_at", where: "(read_at IS NOT NULL)"
    t.index ["household_id"], name: "index_notifications_on_household_id"
    t.index ["user_id", "dedupe_key"], name: "index_notifications_on_user_id_and_dedupe_key", unique: true
    t.index ["user_id", "read_at"], name: "index_notifications_on_user_id_and_read_at"
  end

  create_table "offline_downloads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device_name"
    t.datetime "expires_at", null: false
    t.uuid "household_id", null: false
    t.datetime "last_synced_at"
    t.uuid "media_file_id", null: false
    t.uuid "optimized_version_id"
    t.uuid "playable_id", null: false
    t.string "playable_type", null: false
    t.uuid "profile_id", null: false
    t.bigint "size", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_offline_downloads_on_household_id"
    t.index ["media_file_id"], name: "index_offline_downloads_on_media_file_id"
    t.index ["optimized_version_id"], name: "index_offline_downloads_on_optimized_version_id"
    t.index ["playable_type", "playable_id"], name: "index_offline_downloads_on_playable"
    t.index ["profile_id"], name: "index_offline_downloads_on_profile_id"
  end

  create_table "open_subtitles_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_key", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "household_id", null: false
    t.string "languages", default: ["en"], null: false, array: true
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.text "password"
    t.integer "remaining_downloads"
    t.datetime "resets_at"
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["household_id"], name: "index_open_subtitles_settings_on_household_id", unique: true
  end

  create_table "optimized_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.integer "audio_stream_index"
    t.datetime "created_at", null: false
    t.string "encoder"
    t.text "error"
    t.datetime "finished_at"
    t.datetime "heartbeat_at"
    t.integer "height"
    t.uuid "household_id", null: false
    t.datetime "interrupted_at"
    t.string "interruption"
    t.integer "interruptions", default: 0, null: false
    t.uuid "media_file_id", null: false
    t.datetime "needed_at"
    t.string "origin", default: "automatic", null: false
    t.datetime "prioritized_at"
    t.float "progress", default: 0.0, null: false
    t.string "reason"
    t.boolean "run_now", default: false, null: false
    t.bigint "size"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.boolean "tonemapped", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "worker"
    t.index ["household_id"], name: "index_optimized_versions_on_household_id"
    t.index ["media_file_id"], name: "index_optimized_versions_on_media_file_id", unique: true
    t.index ["state", "needed_at"], name: "index_optimized_versions_on_state_and_needed_at"
  end

  create_table "path_mappings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "local_prefix", null: false
    t.string "remote_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "remote_prefix"], name: "index_path_mappings_on_household_id_and_remote_prefix", unique: true
  end

  create_table "people", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "profile_path"
    t.integer "tmdb_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tmdb_id"], name: "index_people_on_tmdb_id", unique: true
  end

  create_table "playabilities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "client_class", null: false
    t.datetime "created_at", null: false
    t.integer "failures", default: 0, null: false
    t.string "format_signature", null: false
    t.uuid "household_id", null: false
    t.datetime "last_failed_at"
    t.string "last_failure_cause"
    t.string "last_failure_class"
    t.datetime "last_succeeded_at"
    t.uuid "media_file_id", null: false
    t.string "rung", null: false
    t.integer "successes", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "version"
    t.index ["household_id", "format_signature", "client_class", "rung"], name: "index_playabilities_on_format"
    t.index ["media_file_id", "client_class", "rung"], name: "index_playabilities_on_media_file_id_and_client_class_and_rung", unique: true
  end

  create_table "playback_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "detail", default: {}, null: false
    t.string "kind", null: false
    t.uuid "playback_session_id", null: false
    t.float "position_seconds"
    t.index ["kind", "created_at"], name: "index_playback_events_on_kind_and_created_at"
    t.index ["playback_session_id", "created_at"], name: "index_playback_events_on_playback_session_id_and_created_at"
  end

  create_table "playback_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "adaptive", default: false, null: false
    t.uuid "airing_id"
    t.integer "audio_stream_index"
    t.bigint "bytes_sent", default: 0, null: false
    t.string "client_class"
    t.datetime "created_at", null: false
    t.jsonb "decision", default: {}, null: false
    t.uuid "device_id"
    t.string "device_name"
    t.datetime "ended_at"
    t.datetime "failed_at"
    t.string "failure_cause"
    t.string "failure_class"
    t.uuid "fallback_from_id"
    t.uuid "household_id", null: false
    t.float "joined_at_seconds"
    t.datetime "last_seen_at", null: false
    t.uuid "media_file_id"
    t.string "method", null: false
    t.datetime "outcome_recorded_at"
    t.uuid "playable_id", null: false
    t.string "playable_type", null: false
    t.uuid "playlist_id"
    t.float "position_seconds", default: 0.0, null: false
    t.uuid "profile_id", null: false
    t.integer "run_start"
    t.datetime "run_started_at"
    t.integer "segment_target_ms", default: 6000, null: false
    t.boolean "standby", default: false, null: false
    t.float "start_position_seconds"
    t.datetime "started_at", null: false
    t.string "state", default: "active", null: false
    t.string "trakt_scrobble"
    t.datetime "trakt_scrobbled_at"
    t.string "transcode_error"
    t.uuid "transcode_node_id"
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["airing_id"], name: "index_playback_sessions_on_airing_id"
    t.index ["device_id"], name: "index_playback_sessions_on_device_id"
    t.index ["fallback_from_id"], name: "index_playback_sessions_on_fallback_from_id"
    t.index ["household_id", "state", "last_seen_at"], name: "idx_on_household_id_state_last_seen_at_a25b9bd19b"
    t.index ["last_seen_at"], name: "index_playback_sessions_active_on_last_seen_at", where: "((state)::text = 'active'::text)"
    t.index ["media_file_id"], name: "index_playback_sessions_on_media_file_id"
    t.index ["playable_type", "playable_id"], name: "index_playback_sessions_on_playable"
    t.index ["playlist_id"], name: "index_playback_sessions_on_playlist_id"
    t.index ["profile_id"], name: "index_playback_sessions_on_profile_id"
    t.index ["trakt_scrobble"], name: "index_playback_sessions_on_trakt_scrobble", where: "((trakt_scrobble)::text = 'watching'::text)"
    t.index ["transcode_node_id"], name: "index_playback_sessions_on_transcode_node_id"
    t.index ["user_id"], name: "index_playback_sessions_on_user_id"
  end

  create_table "playlist_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "item_id", null: false
    t.string "item_type", null: false
    t.uuid "playlist_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["item_type", "item_id"], name: "index_playlist_items_on_item"
    t.index ["playlist_id", "item_type", "item_id"], name: "index_playlist_items_uniqueness", unique: true
  end

  create_table "playlists", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "plex_key"
    t.uuid "profile_id", null: false
    t.string "system_kind"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_playlists_on_household_id"
    t.index ["profile_id", "plex_key"], name: "index_playlists_on_profile_id_and_plex_key", unique: true, where: "(plex_key IS NOT NULL)"
    t.index ["profile_id", "system_kind"], name: "index_playlists_on_profile_id_and_system_kind", unique: true, where: "(system_kind IS NOT NULL)"
    t.index ["profile_id"], name: "index_playlists_on_profile_id"
  end

  create_table "plex_connections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.datetime "last_synced_at"
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.string "machine_identifier"
    t.string "server_name"
    t.string "server_url", null: false
    t.boolean "sync_enabled", default: false, null: false
    t.text "token", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_plex_connections_on_household_id", unique: true
  end

  create_table "plex_imports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "counts", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "dry_run", default: true, null: false
    t.string "error"
    t.datetime "finished_at"
    t.uuid "household_id", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.jsonb "unmatched", default: [], null: false
    t.datetime "updated_at", null: false
    t.jsonb "users", default: [], null: false
    t.index ["household_id", "created_at"], name: "index_plex_imports_on_household_id_and_created_at"
  end

  create_table "plex_user_mappings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "plex_admin", default: false, null: false
    t.uuid "plex_connection_id", null: false
    t.string "plex_name", null: false
    t.string "plex_user_id", null: false
    t.string "plex_uuid"
    t.uuid "profile_id"
    t.datetime "updated_at", null: false
    t.index ["plex_connection_id", "plex_user_id"], name: "idx_on_plex_connection_id_plex_user_id_6f4ec2884d", unique: true
    t.index ["profile_id"], name: "index_plex_user_mappings_on_profile_id"
  end

  create_table "profile_exclusions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "excludable_id", null: false
    t.string "excludable_type", null: false
    t.uuid "profile_id", null: false
    t.datetime "updated_at", null: false
    t.index ["excludable_type", "excludable_id"], name: "index_profile_exclusions_on_excludable"
    t.index ["profile_id", "excludable_type", "excludable_id"], name: "index_profile_exclusions_uniqueness", unique: true
  end

  create_table "profile_notices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "profile_id", null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.index ["profile_id", "subject_type", "subject_id"], name: "index_profile_notices_uniqueness", unique: true
    t.index ["subject_type", "subject_id"], name: "index_profile_notices_on_subject"
  end

  create_table "profile_tags", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "profile_id", null: false
    t.uuid "taggable_id", null: false
    t.string "taggable_type", null: false
    t.datetime "updated_at", null: false
    t.index ["profile_id", "taggable_type", "taggable_id"], name: "index_profile_tags_uniqueness", unique: true
    t.index ["taggable_type", "taggable_id"], name: "index_profile_tags_on_taggable"
  end

  create_table "profiles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "allow_unrated", default: false, null: false
    t.boolean "always_skip_credits", default: false, null: false
    t.boolean "always_skip_intro", default: false, null: false
    t.boolean "autoplay_videos", default: false, null: false
    t.string "avatar"
    t.string "color", default: "#e5a50a", null: false
    t.datetime "created_at", null: false
    t.boolean "curated", default: false, null: false
    t.jsonb "home_layout", default: {}, null: false
    t.uuid "household_id", null: false
    t.string "kind", default: "standard", null: false
    t.uuid "library_ids", default: [], null: false, array: true
    t.integer "max_rating_age"
    t.string "name", null: false
    t.boolean "notify_new_episodes", default: true, null: false
    t.boolean "notify_subscriptions", default: true, null: false
    t.string "ntfy_topic"
    t.datetime "pin_changed_at"
    t.string "pin_digest"
    t.integer "position", default: 0, null: false
    t.jsonb "sidebar", default: {}, null: false
    t.jsonb "sponsorblock", default: {}, null: false
    t.integer "still_watching_after"
    t.integer "up_next_seconds"
    t.datetime "updated_at", null: false
    t.index ["household_id", "name"], name: "index_profiles_on_household_id_and_name", unique: true
  end

  create_table "ratings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "profile_id", null: false
    t.uuid "rateable_id", null: false
    t.string "rateable_type", null: false
    t.datetime "rated_at", null: false
    t.datetime "updated_at", null: false
    t.float "value", null: false
    t.index ["profile_id", "rateable_type", "rateable_id"], name: "index_ratings_uniqueness", unique: true
    t.index ["rateable_type", "rateable_id"], name: "index_ratings_on_rateable"
  end

  create_table "seasons", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.date "air_date"
    t.datetime "created_at", null: false
    t.integer "episode_count"
    t.text "overview"
    t.string "poster_path"
    t.integer "season_number", null: false
    t.uuid "show_id", null: false
    t.string "title"
    t.integer "tmdb_id"
    t.datetime "updated_at", null: false
    t.index ["show_id", "season_number"], name: "index_seasons_on_show_id_and_season_number", unique: true
  end

  create_table "show_folders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "folder", null: false
    t.uuid "household_id", null: false
    t.uuid "library_id", null: false
    t.uuid "show_id", null: false
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_show_folders_on_household_id"
    t.index ["library_id", "folder"], name: "index_show_folders_on_library_id_and_folder", unique: true
    t.index ["show_id"], name: "index_show_folders_on_show_id"
  end

  create_table "show_preferences", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "profile_id", null: false
    t.uuid "show_id", null: false
    t.boolean "skip_credits", default: false, null: false
    t.boolean "skip_intro", default: false, null: false
    t.boolean "skip_recap", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["profile_id", "show_id"], name: "index_show_preferences_on_profile_id_and_show_id", unique: true
    t.index ["show_id"], name: "index_show_preferences_on_show_id"
  end

  create_table "shows", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "backdrop_path"
    t.string "content_rating"
    t.datetime "created_at", null: false
    t.datetime "embedded_at"
    t.vector "embedding", limit: 512
    t.date "first_air_date"
    t.string "folder", null: false
    t.string "genres", default: [], null: false, array: true
    t.uuid "household_id", null: false
    t.string "imdb_id"
    t.string "keywords", default: [], null: false, array: true
    t.uuid "library_id", null: false
    t.string "locked_fields", default: [], null: false, array: true
    t.string "logo_path"
    t.jsonb "match_candidates", default: [], null: false
    t.jsonb "match_reasons", default: {}, null: false
    t.float "match_score"
    t.string "match_state", default: "unmatched", null: false
    t.datetime "metadata_refreshed_at"
    t.string "network"
    t.string "networks", default: [], null: false, array: true
    t.string "original_title"
    t.text "overview"
    t.string "poster_path"
    t.integer "rating_age"
    t.string "sort_title", null: false
    t.string "status"
    t.string "title", null: false
    t.integer "tmdb_id"
    t.datetime "trailer_checked_at"
    t.integer "tvdb_id"
    t.datetime "updated_at", null: false
    t.float "vote_average"
    t.integer "year"
    t.index ["embedding"], name: "index_shows_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["household_id", "imdb_id"], name: "index_shows_on_household_id_and_imdb_id"
    t.index ["household_id", "tmdb_id"], name: "index_shows_on_household_id_and_tmdb_id"
    t.index ["household_id", "tvdb_id"], name: "index_shows_on_household_id_and_tvdb_id"
    t.index ["keywords"], name: "index_shows_on_keywords", using: :gin
    t.index ["library_id", "folder"], name: "index_shows_on_library_id_and_folder", unique: true
    t.index ["library_id", "match_state"], name: "index_shows_on_library_id_and_match_state"
    t.index ["networks"], name: "index_shows_on_networks", using: :gin
    t.index ["sort_title"], name: "index_shows_on_sort_title"
  end

  create_table "sponsor_segments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.float "end_seconds", null: false
    t.float "start_seconds", null: false
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.uuid "video_id", null: false
    t.index ["video_id", "uuid"], name: "index_sponsor_segments_on_video_id_and_uuid", unique: true
  end

  create_table "station_blocks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "days", default: 127, null: false
    t.integer "end_minute"
    t.date "ends_on"
    t.string "layer", null: false
    t.boolean "loops", default: true, null: false
    t.integer "marathon_length", default: 3, null: false
    t.string "name"
    t.string "ordering", default: "shuffle", null: false
    t.integer "position", default: 0, null: false
    t.jsonb "source", default: {}, null: false
    t.integer "start_minute"
    t.date "starts_on"
    t.uuid "station_id", null: false
    t.datetime "updated_at", null: false
    t.index ["station_id"], name: "index_station_blocks_on_station_id"
  end

  create_table "station_favorites", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "profile_id", null: false
    t.uuid "station_id", null: false
    t.index ["profile_id", "station_id"], name: "index_station_favorites_on_profile_id_and_station_id", unique: true
    t.index ["station_id"], name: "index_station_favorites_on_station_id"
  end

  create_table "station_hides", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "profile_id", null: false
    t.uuid "station_id", null: false
    t.index ["profile_id", "station_id"], name: "index_station_hides_on_profile_id_and_station_id", unique: true
    t.index ["station_id"], name: "index_station_hides_on_station_id"
  end

  create_table "stations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "breaks", default: false, null: false
    t.string "call_sign"
    t.datetime "created_at", null: false
    t.string "filler", default: "slate", null: false
    t.uuid "filler_channel_ids", default: [], null: false, array: true
    t.uuid "household_id", null: false
    t.string "last_error"
    t.datetime "last_scheduled_at"
    t.uuid "live_stream_id"
    t.integer "mlb_team_ids", default: [], null: false, array: true
    t.string "name", null: false
    t.integer "no_repeat_days", default: 3, null: false
    t.string "number", null: false
    t.integer "number_major", null: false
    t.integer "number_minor", default: 0, null: false
    t.datetime "scheduled_through"
    t.integer "snap_minutes", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["household_id", "number"], name: "index_stations_on_household_id_and_number", unique: true
    t.index ["household_id", "number_major", "number_minor"], name: "idx_on_household_id_number_major_number_minor_26d2b7d8f8"
    t.index ["live_stream_id"], name: "index_stations_on_live_stream_id"
  end

  create_table "tmdb_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_key"
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_tmdb_settings_on_household_id", unique: true
  end

  create_table "trailers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "fetched_at"
    t.uuid "household_id", null: false
    t.string "name"
    t.uuid "owner_id", null: false
    t.string "owner_type", null: false
    t.bigint "size"
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.string "youtube_id", null: false
    t.index ["household_id"], name: "index_trailers_on_household_id"
    t.index ["owner_type", "owner_id"], name: "index_trailers_on_owner", unique: true
  end

  create_table "trakt_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token"
    t.datetime "created_at", null: false
    t.text "device_code"
    t.datetime "device_expires_at"
    t.datetime "expires_at"
    t.uuid "household_id", null: false
    t.jsonb "last_activities", default: {}, null: false
    t.string "last_error"
    t.datetime "last_error_at"
    t.datetime "last_synced_at"
    t.datetime "linked_at"
    t.integer "poll_interval"
    t.datetime "polled_at"
    t.uuid "profile_id", null: false
    t.text "refresh_token"
    t.string "state", default: "pending", null: false
    t.jsonb "synced_keys", default: {}, null: false
    t.datetime "updated_at", null: false
    t.string "user_code"
    t.string "username"
    t.string "verification_url"
    t.index ["household_id"], name: "index_trakt_accounts_on_household_id"
    t.index ["profile_id"], name: "index_trakt_accounts_on_profile_id", unique: true
  end

  create_table "trakt_changes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.uuid "item_id", null: false
    t.string "item_type", null: false
    t.string "last_error"
    t.integer "rating"
    t.uuid "trakt_account_id", null: false
    t.datetime "watched_at"
    t.index ["trakt_account_id", "created_at"], name: "index_trakt_changes_on_trakt_account_id_and_created_at"
  end

  create_table "trakt_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "client_id", null: false
    t.text "client_secret", null: false
    t.datetime "created_at", null: false
    t.uuid "household_id", null: false
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.datetime "updated_at", null: false
    t.index ["household_id"], name: "index_trakt_settings_on_household_id", unique: true
  end

  create_table "transcode_nodes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "capabilities", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "encoder"
    t.string "fog_pool"
    t.datetime "last_seen_at"
    t.integer "max_sessions", default: 2, null: false
    t.string "name", null: false
    t.boolean "optimize", default: true, null: false
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.index ["fog_pool"], name: "index_transcode_nodes_on_fog_pool", unique: true, where: "(fog_pool IS NOT NULL)"
    t.index ["token_digest"], name: "index_transcode_nodes_on_token_digest", unique: true
  end

  create_table "transcode_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "argv", default: [], null: false
    t.datetime "created_at", null: false
    t.string "encoder"
    t.integer "exit_status"
    t.string "failure"
    t.datetime "finished_at"
    t.text "log_tail"
    t.uuid "optimized_version_id"
    t.uuid "playback_session_id"
    t.float "progress_seconds"
    t.integer "signal"
    t.integer "start_gop"
    t.datetime "started_at"
    t.string "state", default: "pending", null: false
    t.uuid "transcode_node_id"
    t.datetime "updated_at", null: false
    t.integer "variant", default: 0, null: false
    t.index ["created_at"], name: "index_transcode_runs_on_created_at"
    t.index ["failure"], name: "index_transcode_runs_on_failure", where: "(failure IS NOT NULL)"
    t.index ["optimized_version_id"], name: "index_transcode_runs_on_optimized_version_id"
    t.index ["playback_session_id"], name: "index_transcode_runs_on_playback_session_id"
    t.index ["transcode_node_id", "state"], name: "index_transcode_runs_on_transcode_node_id_and_state"
  end

  create_table "transcoder_beats", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "busy", default: false, null: false
    t.datetime "created_at", null: false
    t.string "encoder", null: false
    t.string "host", null: false
    t.datetime "seen_at", null: false
    t.datetime "updated_at", null: false
    t.index ["host"], name: "index_transcoder_beats_on_host", unique: true
  end

  create_table "transcript_lines", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.float "end_seconds", null: false
    t.uuid "media_file_id", null: false
    t.float "start_seconds", null: false
    t.text "text", null: false
    t.uuid "transcript_id", null: false
    t.virtual "tsv", type: :tsvector, as: "to_tsvector('english'::regconfig, text)", stored: true
    t.index ["media_file_id", "start_seconds"], name: "index_transcript_lines_on_media_file_id_and_start_seconds"
    t.index ["transcript_id"], name: "index_transcript_lines_on_transcript_id"
    t.index ["tsv"], name: "index_transcript_lines_on_tsv", using: :gin
  end

  create_table "transcripts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "language"
    t.integer "line_count", default: 0, null: false
    t.uuid "media_file_id", null: false
    t.string "source", null: false
    t.string "track_id"
    t.datetime "updated_at", null: false
    t.index ["media_file_id"], name: "index_transcripts_on_media_file_id", unique: true
  end

  create_table "trickplays", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "columns", null: false
    t.datetime "created_at", null: false
    t.integer "interval_seconds", null: false
    t.uuid "media_file_id", null: false
    t.integer "rows", null: false
    t.integer "sheet_count", null: false
    t.integer "thumbnail_count", null: false
    t.integer "tile_height", null: false
    t.integer "tile_width", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 0, null: false
    t.index ["media_file_id"], name: "index_trickplays_on_media_file_id", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.citext "email", null: false
    t.uuid "household_id", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.string "visitor_home"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["household_id"], name: "index_users_on_household_id"
  end

  create_table "videos", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.jsonb "chapters", default: [], null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "embedded_at"
    t.vector "embedding", limit: 512
    t.uuid "household_id", null: false
    t.string "identity", default: "unchecked", null: false
    t.uuid "library_id", null: false
    t.string "locked_fields", default: [], null: false, array: true
    t.string "sort_title", null: false
    t.string "source", null: false
    t.datetime "sponsorblock_checked_at"
    t.string "tags", default: [], null: false, array: true
    t.string "thumbnail_url"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.date "upload_date"
    t.string "url"
    t.jsonb "youtube_candidates", default: [], null: false
    t.string "youtube_id"
    t.index ["channel_id", "identity"], name: "index_videos_on_channel_id_and_identity"
    t.index ["channel_id", "upload_date"], name: "index_videos_on_channel_id_and_upload_date"
    t.index ["embedding"], name: "index_videos_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["household_id"], name: "index_videos_on_household_id"
    t.index ["library_id", "youtube_id"], name: "index_videos_on_library_id_and_youtube_id", unique: true, where: "(youtube_id IS NOT NULL)"
    t.index ["library_id"], name: "index_videos_on_library_id"
  end

  create_table "watch_states", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.boolean "hidden_from_continue", default: false, null: false
    t.datetime "last_watched_at"
    t.uuid "media_file_id"
    t.integer "play_count", default: 0, null: false
    t.uuid "playable_id", null: false
    t.string "playable_type", null: false
    t.float "position_seconds", default: 0.0, null: false
    t.uuid "profile_id", null: false
    t.datetime "updated_at", null: false
    t.index ["media_file_id"], name: "index_watch_states_on_media_file_id"
    t.index ["playable_type", "playable_id"], name: "index_watch_states_on_playable_type_and_playable_id"
    t.index ["profile_id", "last_watched_at"], name: "index_watch_states_on_profile_id_and_last_watched_at"
    t.index ["profile_id", "playable_type", "playable_id"], name: "index_watch_states_uniqueness", unique: true
  end

  create_table "webauthn_credentials", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.datetime "last_used_at"
    t.string "nickname"
    t.text "public_key", null: false
    t.bigint "sign_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
    t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
  end

  create_table "whisper_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "api_key"
    t.string "api_kind", default: "asr_webservice", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "household_id", null: false
    t.string "last_test_message"
    t.boolean "last_test_ok"
    t.datetime "last_tested_at"
    t.string "model"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["household_id"], name: "index_whisper_settings_on_household_id", unique: true
  end

  create_table "youtube_downloads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.boolean "by_hand", default: false, null: false
    t.bigint "bytes"
    t.uuid "channel_id", null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.uuid "household_id", null: false
    t.boolean "kept", default: false, null: false
    t.string "last_error"
    t.string "path"
    t.string "reason"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "youtube_id", null: false
    t.index ["channel_id", "youtube_id"], name: "index_youtube_downloads_on_channel_id_and_youtube_id", unique: true
    t.index ["household_id", "state"], name: "index_youtube_downloads_on_household_id_and_state"
  end

  add_foreign_key "activity_entries", "households", on_delete: :cascade
  add_foreign_key "airing_reminders", "airings", on_delete: :cascade
  add_foreign_key "airing_reminders", "profiles", on_delete: :cascade
  add_foreign_key "airing_reminders", "users", on_delete: :cascade
  add_foreign_key "airings", "households", on_delete: :cascade
  add_foreign_key "airings", "media_files", on_delete: :cascade
  add_foreign_key "airings", "station_blocks", on_delete: :nullify
  add_foreign_key "airings", "stations", on_delete: :cascade
  add_foreign_key "album_clips", "albums", on_delete: :cascade
  add_foreign_key "album_clips", "clips", on_delete: :cascade
  add_foreign_key "albums", "households", on_delete: :cascade
  add_foreign_key "analysis_runs", "live_streams", on_delete: :cascade
  add_foreign_key "analysis_runs", "media_files", on_delete: :cascade
  add_foreign_key "api_sessions", "users", on_delete: :cascade
  add_foreign_key "api_tokens", "users", on_delete: :cascade
  add_foreign_key "arr_webhooks", "households", on_delete: :cascade
  add_foreign_key "audio_fingerprints", "media_files", on_delete: :cascade
  add_foreign_key "channel_subscriptions", "channels", on_delete: :cascade
  add_foreign_key "channel_subscriptions", "profiles", on_delete: :cascade
  add_foreign_key "channels", "households", on_delete: :cascade
  add_foreign_key "channels", "libraries", on_delete: :cascade
  add_foreign_key "clip_people", "clips", on_delete: :cascade
  add_foreign_key "clip_people", "home_people", on_delete: :cascade
  add_foreign_key "clips", "households", on_delete: :cascade
  add_foreign_key "clips", "libraries", on_delete: :cascade
  add_foreign_key "collection_items", "collections", on_delete: :cascade
  add_foreign_key "collection_parts", "collections", on_delete: :cascade
  add_foreign_key "collection_parts", "households", on_delete: :cascade
  add_foreign_key "collections", "households", on_delete: :cascade
  add_foreign_key "collections", "libraries", on_delete: :nullify
  add_foreign_key "credits", "people", on_delete: :cascade
  add_foreign_key "device_commands", "devices", on_delete: :cascade
  add_foreign_key "device_commands", "households", on_delete: :cascade
  add_foreign_key "device_commands", "users", on_delete: :nullify
  add_foreign_key "device_pairings", "households", on_delete: :cascade
  add_foreign_key "device_pairings", "users", on_delete: :cascade
  add_foreign_key "devices", "households", on_delete: :cascade
  add_foreign_key "devices", "profiles", column: "default_profile_id", on_delete: :nullify
  add_foreign_key "editions", "media_files", on_delete: :cascade
  add_foreign_key "episodes", "seasons", on_delete: :cascade
  add_foreign_key "episodes", "shows", on_delete: :cascade
  add_foreign_key "extras", "households", on_delete: :cascade
  add_foreign_key "extras", "media_files", on_delete: :cascade
  add_foreign_key "fog_integrations", "api_tokens", on_delete: :nullify
  add_foreign_key "fog_integrations", "households", on_delete: :cascade
  add_foreign_key "folder_listings", "households", on_delete: :cascade
  add_foreign_key "folder_listings", "libraries", on_delete: :cascade
  add_foreign_key "home_people", "households", on_delete: :cascade
  add_foreign_key "identities", "users", on_delete: :cascade
  add_foreign_key "immich_settings", "households", on_delete: :cascade
  add_foreign_key "invite_codes", "households", on_delete: :cascade
  add_foreign_key "invite_codes", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "job_runs", "households", on_delete: :cascade
  add_foreign_key "libraries", "households", on_delete: :cascade
  add_foreign_key "live_streams", "households", on_delete: :cascade
  add_foreign_key "live_streams", "libraries", on_delete: :cascade
  add_foreign_key "markers", "media_files", on_delete: :cascade
  add_foreign_key "media_files", "households", on_delete: :cascade
  add_foreign_key "media_files", "libraries", on_delete: :cascade
  add_foreign_key "media_streams", "live_streams", on_delete: :cascade
  add_foreign_key "media_streams", "media_files", on_delete: :cascade
  add_foreign_key "mlb_settings", "households", on_delete: :cascade
  add_foreign_key "movies", "households", on_delete: :cascade
  add_foreign_key "movies", "libraries", on_delete: :cascade
  add_foreign_key "nba_settings", "households", on_delete: :cascade
  add_foreign_key "notifications", "households", on_delete: :cascade
  add_foreign_key "notifications", "users", on_delete: :cascade
  add_foreign_key "offline_downloads", "households", on_delete: :cascade
  add_foreign_key "offline_downloads", "media_files", on_delete: :cascade
  add_foreign_key "offline_downloads", "optimized_versions", on_delete: :cascade
  add_foreign_key "offline_downloads", "profiles", on_delete: :cascade
  add_foreign_key "open_subtitles_settings", "households", on_delete: :cascade
  add_foreign_key "optimized_versions", "households", on_delete: :cascade
  add_foreign_key "optimized_versions", "media_files", on_delete: :cascade
  add_foreign_key "path_mappings", "households", on_delete: :cascade
  add_foreign_key "playabilities", "households", on_delete: :cascade
  add_foreign_key "playabilities", "media_files", on_delete: :cascade
  add_foreign_key "playback_events", "playback_sessions", on_delete: :cascade
  add_foreign_key "playback_sessions", "airings", on_delete: :nullify
  add_foreign_key "playback_sessions", "devices", on_delete: :nullify
  add_foreign_key "playback_sessions", "households", on_delete: :cascade
  add_foreign_key "playback_sessions", "media_files", on_delete: :cascade
  add_foreign_key "playback_sessions", "playback_sessions", column: "fallback_from_id", on_delete: :nullify
  add_foreign_key "playback_sessions", "playlists", on_delete: :nullify
  add_foreign_key "playback_sessions", "profiles", on_delete: :cascade
  add_foreign_key "playback_sessions", "transcode_nodes", on_delete: :nullify
  add_foreign_key "playback_sessions", "users", on_delete: :nullify
  add_foreign_key "playlist_items", "playlists", on_delete: :cascade
  add_foreign_key "playlists", "households", on_delete: :cascade
  add_foreign_key "playlists", "profiles", on_delete: :cascade
  add_foreign_key "plex_connections", "households", on_delete: :cascade
  add_foreign_key "plex_imports", "households", on_delete: :cascade
  add_foreign_key "plex_user_mappings", "plex_connections", on_delete: :cascade
  add_foreign_key "plex_user_mappings", "profiles", on_delete: :nullify
  add_foreign_key "profile_exclusions", "profiles", on_delete: :cascade
  add_foreign_key "profile_notices", "profiles", on_delete: :cascade
  add_foreign_key "profile_tags", "profiles", on_delete: :cascade
  add_foreign_key "profiles", "households", on_delete: :cascade
  add_foreign_key "ratings", "profiles", on_delete: :cascade
  add_foreign_key "seasons", "shows", on_delete: :cascade
  add_foreign_key "show_folders", "households", on_delete: :cascade
  add_foreign_key "show_folders", "libraries", on_delete: :cascade
  add_foreign_key "show_folders", "shows", on_delete: :cascade
  add_foreign_key "show_preferences", "profiles", on_delete: :cascade
  add_foreign_key "show_preferences", "shows", on_delete: :cascade
  add_foreign_key "shows", "households", on_delete: :cascade
  add_foreign_key "shows", "libraries", on_delete: :cascade
  add_foreign_key "sponsor_segments", "videos", on_delete: :cascade
  add_foreign_key "station_blocks", "stations", on_delete: :cascade
  add_foreign_key "station_favorites", "profiles", on_delete: :cascade
  add_foreign_key "station_favorites", "stations", on_delete: :cascade
  add_foreign_key "station_hides", "profiles", on_delete: :cascade
  add_foreign_key "station_hides", "stations", on_delete: :cascade
  add_foreign_key "stations", "households", on_delete: :cascade
  add_foreign_key "stations", "live_streams", on_delete: :nullify
  add_foreign_key "tmdb_settings", "households", on_delete: :cascade
  add_foreign_key "trailers", "households", on_delete: :cascade
  add_foreign_key "trakt_accounts", "households", on_delete: :cascade
  add_foreign_key "trakt_accounts", "profiles", on_delete: :cascade
  add_foreign_key "trakt_changes", "trakt_accounts", on_delete: :cascade
  add_foreign_key "trakt_settings", "households", on_delete: :cascade
  add_foreign_key "transcode_runs", "optimized_versions", on_delete: :cascade
  add_foreign_key "transcode_runs", "playback_sessions", on_delete: :cascade
  add_foreign_key "transcode_runs", "transcode_nodes", on_delete: :cascade
  add_foreign_key "transcript_lines", "media_files", on_delete: :cascade
  add_foreign_key "transcript_lines", "transcripts", on_delete: :cascade
  add_foreign_key "transcripts", "media_files", on_delete: :cascade
  add_foreign_key "trickplays", "media_files", on_delete: :cascade
  add_foreign_key "users", "households", on_delete: :cascade
  add_foreign_key "videos", "channels", on_delete: :cascade
  add_foreign_key "videos", "households", on_delete: :cascade
  add_foreign_key "videos", "libraries", on_delete: :cascade
  add_foreign_key "watch_states", "media_files", on_delete: :nullify
  add_foreign_key "watch_states", "profiles", on_delete: :cascade
  add_foreign_key "webauthn_credentials", "users", on_delete: :cascade
  add_foreign_key "whisper_settings", "households", on_delete: :cascade
  add_foreign_key "youtube_downloads", "channels", on_delete: :cascade
  add_foreign_key "youtube_downloads", "households", on_delete: :cascade
end
