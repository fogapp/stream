# typed: false
# frozen_string_literal: true

# Remote transcoders (PROPOSAL §11 Phase 6): another machine — a Mac mini
# with VideoToolbox — converting video for Stream over HTTP. The fog
# transcoder still decides everything; a node polls for the ffmpeg runs it
# was given, reads the original through a signed URL and uploads what it
# makes into the cache.
class CreateTranscodeNodes < ActiveRecord::Migration[8.1]
  def change
    create_table :transcode_nodes, id: :uuid do |t|
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.boolean :enabled, null: false, default: true
      # Also encodes optimized versions when it's idle.
      t.boolean :optimize, null: false, default: true
      t.integer :max_sessions, null: false, default: 2
      # What the worker reported: encoder, filters, ffmpeg version, host.
      t.string :encoder
      t.jsonb :capabilities, null: false, default: {}
      t.datetime :last_seen_at
      t.timestamps
      t.index :token_digest, unique: true
    end

    create_table :transcode_runs, id: :uuid do |t|
      t.references :transcode_node, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :playback_session, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :optimized_version, type: :uuid, foreign_key: { on_delete: :cascade }
      t.jsonb :argv, null: false, default: []
      t.string :state, null: false, default: "pending"
      t.integer :exit_status
      t.text :log_tail
      t.float :progress_seconds
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[transcode_node_id state]
    end

    add_reference :playback_sessions, :transcode_node, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
