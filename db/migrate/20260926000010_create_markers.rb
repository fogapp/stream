# typed: false
# frozen_string_literal: true

# Skippable spans of a file (PROPOSAL §4.3, §5.5): intro, recap, credits.
# From the file's chapters, from matching audio across a season, or set by
# a person — and each profile's wish to always skip them, per show.
class CreateMarkers < ActiveRecord::Migration[8.1]
  def change
    create_table :markers, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.float :start_seconds, null: false
      t.float :end_seconds, null: false
      # chapter | detected | manual. A manual marker is never overwritten.
      t.string :source, null: false
      t.float :confidence, null: false, default: 1.0
      t.timestamps
      t.index %i[media_file_id kind], unique: true
    end

    # Chromaprint fingerprints of a file's opening and closing minutes,
    # kept so re-running a season's detection doesn't read every file again.
    create_table :audio_fingerprints, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :segment, null: false
      t.float :offset_seconds, null: false
      t.integer :points, array: true, null: false, default: []
      t.timestamps
      t.index %i[media_file_id segment], unique: true
    end

    create_table :show_preferences, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :show, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.boolean :skip_intro, null: false, default: false
      t.boolean :skip_recap, null: false, default: false
      t.boolean :skip_credits, null: false, default: false
      t.timestamps
      t.index %i[profile_id show_id], unique: true
    end
  end
end
