# typed: false
# frozen_string_literal: true

# Migrating from Plex, part 1 (PROPOSAL §7.4, §11): a read-only connection
# to a Plex server, who in Plex is who in Stream, and a record of every dry
# run and import so a re-sync can say what it changed.
class CreatePlexMigration < ActiveRecord::Migration[8.1]
  def change
    create_table :plex_connections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :server_url, null: false
      t.text :token, null: false
      t.string :machine_identifier
      t.string :server_name
      t.boolean :sync_enabled, null: false, default: false
      t.datetime :last_synced_at
      t.datetime :last_tested_at
      t.boolean :last_test_ok
      t.string :last_test_message
      t.timestamps
    end

    create_table :plex_user_mappings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :plex_connection, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :plex_user_id, null: false
      t.string :plex_uuid
      t.string :plex_name, null: false
      t.boolean :plex_admin, null: false, default: false
      # nil: this Plex user isn't imported.
      t.references :profile, type: :uuid, foreign_key: { on_delete: :nullify }
      t.timestamps
      t.index %i[plex_connection_id plex_user_id], unique: true
    end

    create_table :plex_imports, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.boolean :dry_run, null: false, default: true
      t.string :status, null: false, default: "queued"
      t.jsonb :counts, null: false, default: {}
      t.jsonb :unmatched, null: false, default: []
      t.jsonb :users, null: false, default: []
      t.string :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[household_id created_at]
    end
  end
end
