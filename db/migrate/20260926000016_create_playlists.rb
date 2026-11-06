# typed: false
# frozen_string_literal: true

# Playlists (PROPOSAL §7.4, and Phase 4's queues): a profile's own list of
# movies and episodes, played in order. A session started from one knows
# it, so Up next is the playlist's next item.
class CreatePlaylists < ActiveRecord::Migration[8.1]
  def change
    create_table :playlists, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :title, null: false
      t.string :plex_key
      t.timestamps
      t.index %i[profile_id plex_key], unique: true, where: "plex_key IS NOT NULL"
    end

    create_table :playlist_items, id: :uuid do |t|
      t.references :playlist, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :item, type: :uuid, polymorphic: true, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index %i[playlist_id item_type item_id], unique: true, name: "index_playlist_items_uniqueness"
    end

    add_reference :playback_sessions, :playlist, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
