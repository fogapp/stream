# typed: false
# frozen_string_literal: true

# Phase 1's file layer (PROPOSAL §4.1, §4.3): libraries and their roots, the
# files found under them identified by content, the streams ffprobe saw in
# each, and one AnalysisRun row per file per step.
class CreateLibrariesAndMediaFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :libraries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :kind, null: false
      # Absolute paths as seen inside the container, validated with
      # StorageLocation before saving. Never written to (CLAUDE.md invariant 1).
      t.string :roots, array: true, null: false, default: []
      t.string :metadata_language, null: false, default: "en"
      t.datetime :last_scanned_at
      t.datetime :last_scan_started_at
      t.string :last_scan_error
      t.integer :consecutive_scan_failures, null: false, default: 0
      t.jsonb :last_scan_counts, null: false, default: {}
      t.timestamps
      t.index %i[household_id name], unique: true
    end

    create_table :media_files, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :path, null: false
      t.bigint :size, null: false
      t.datetime :mtime, null: false
      # OpenSubtitles hash: size + first/last 64 KiB. Stable across moves.
      t.string :fingerprint
      t.string :state, null: false, default: "discovered"
      t.string :container
      t.float :duration_seconds
      t.bigint :bit_rate
      t.jsonb :probe, null: false, default: {}
      t.datetime :probed_at
      t.datetime :missing_since
      t.string :last_error
      t.timestamps
      t.index %i[household_id path], unique: true
      t.index %i[household_id fingerprint]
      t.index %i[library_id state]
    end

    create_table :media_streams, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :index, null: false
      t.string :kind, null: false
      t.string :codec
      t.string :profile
      t.integer :level
      t.integer :bit_depth
      t.integer :width
      t.integer :height
      t.float :frame_rate
      t.string :pixel_format
      t.string :color_primaries
      t.string :color_transfer
      t.string :hdr_format
      t.integer :dolby_vision_profile
      t.integer :channels
      t.string :channel_layout
      t.string :language
      t.string :title
      t.bigint :bit_rate
      t.boolean :default, null: false, default: false
      t.boolean :forced, null: false, default: false
      t.timestamps
      t.index %i[media_file_id index], unique: true
    end

    create_table :analysis_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :step, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :duration_ms
      t.string :tool_version
      t.string :error
      t.integer :consecutive_failures, null: false, default: 0
      t.timestamps
      t.index %i[media_file_id step], unique: true
      t.index %i[step status]
    end
  end
end
