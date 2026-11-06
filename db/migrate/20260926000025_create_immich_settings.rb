# typed: false
# frozen_string_literal: true

# Immich (PROPOSAL §5.4): a read-only sync of home videos' albums, people,
# places and capture times. Immich and Stream mount the same originals at
# different paths; the mapping turns one into the other.
class CreateImmichSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :immich_settings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :url, null: false
      t.text :api_key, null: false
      # "/usr/src/app/upload" as Immich sees it → "/media/immich" as Stream does.
      t.string :immich_path_prefix
      t.string :local_path_prefix
      t.boolean :enabled, null: false, default: true
      t.boolean :last_test_ok
      t.string :last_test_message
      t.datetime :last_tested_at
      t.datetime :last_synced_at
      t.string :last_sync_error
      t.jsonb :last_sync_counts, null: false, default: {}
      t.timestamps
    end
  end
end
