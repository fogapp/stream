# typed: false
# frozen_string_literal: true

# Who is watching and how far they got (PROPOSAL §4.4). Phase 1 gives every
# household one default profile; Phase 5 adds the picker, PINs, kid
# profiles and per-device defaults on these same rows.
class CreateViewing < ActiveRecord::Migration[8.1]
  def change
    create_table :profiles, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :color, null: false, default: "#e5a50a"
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index %i[household_id name], unique: true
    end

    create_table :watch_states, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :playable, type: :uuid, polymorphic: true, null: false, index: false
      # The file last played, so resume picks the same edition.
      t.references :media_file, type: :uuid, foreign_key: { on_delete: :nullify }
      t.float :position_seconds, null: false, default: 0
      t.float :duration_seconds
      t.integer :play_count, null: false, default: 0
      t.datetime :completed_at
      t.datetime :last_watched_at
      t.boolean :hidden_from_continue, null: false, default: false
      t.timestamps
      t.index %i[profile_id playable_type playable_id], unique: true, name: "index_watch_states_uniqueness"
      t.index %i[profile_id last_watched_at]
    end

    create_table :playback_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :playable, type: :uuid, polymorphic: true, null: false
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # direct | remux | audio_transcode | video_transcode. Phase 1 plays
      # direct only; the decision column fills out in Phase 2.
      t.string :method, null: false
      t.jsonb :decision, null: false, default: {}
      t.string :state, null: false, default: "active"
      t.string :device
      t.float :position_seconds, null: false, default: 0
      t.datetime :started_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :ended_at
      t.timestamps
      t.index %i[household_id state last_seen_at]
    end
  end
end
