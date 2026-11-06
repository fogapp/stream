# typed: false
# frozen_string_literal: true

# Scrubbing (PROPOSAL §5.5, §7.3): thumbnail sprite sheets for the seek bar,
# and the chapters a file carries.
class CreateTrickplayAndChapters < ActiveRecord::Migration[8.1]
  def change
    create_table :trickplays, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # Bumped on every render; part of the path, so a re-render never
      # serves a half-written sheet.
      t.integer :version, null: false, default: 0
      t.integer :interval_seconds, null: false
      t.integer :tile_width, null: false
      t.integer :tile_height, null: false
      t.integer :columns, null: false
      t.integer :rows, null: false
      t.integer :sheet_count, null: false
      t.integer :thumbnail_count, null: false
      t.timestamps
    end

    # [{ "start" => seconds, "end" => seconds, "title" => "…" }], from the
    # container at probe time.
    add_column :media_files, :chapters, :jsonb, null: false, default: []
  end
end
