# typed: false
# frozen_string_literal: true

# Offline downloads (PROPOSAL §11 Phase 6): a file this browser plays as-is,
# fetched into it for a flight. The row is what the download URL signs, so
# deleting it (or letting it expire) revokes the link; the bytes live in
# the browser.
class CreateOfflineDownloads < ActiveRecord::Migration[8.1]
  def change
    create_table :offline_downloads, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :playable, type: :uuid, polymorphic: true, null: false
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :optimized_version, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :device_name
      t.bigint :size, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_synced_at
      t.timestamps
    end
  end
end
