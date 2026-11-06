# typed: false
# frozen_string_literal: true

# Optimized versions (PROPOSAL §5.5, §6.3): an H.264 copy of a file some
# device can't decode, encoded in quiet hours so pressing Play plays it
# as-is instead of converting live.
class CreateOptimizedVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :optimized_versions, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :state, null: false, default: "queued"
      # Who asked: an admin ("manual", encoded first and allowed outside quiet
      # hours) or the nightly pass ("automatic").
      t.string :origin, null: false, default: "automatic"
      t.boolean :run_now, null: false, default: false
      t.float :progress, null: false, default: 0
      t.integer :height
      t.bigint :size
      t.integer :audio_stream_index
      t.boolean :tonemapped, null: false, default: false
      t.string :encoder
      t.text :error
      t.integer :attempts, null: false, default: 0
      # Which transcoder is encoding it, and when it last said so: a row
      # whose transcoder died goes back in the queue.
      t.string :worker
      t.datetime :heartbeat_at
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index :state
    end

    change_table :app_settings, bulk: true do |t|
      t.integer :optimize_quiet_start_hour, null: false, default: 1
      t.integer :optimize_quiet_end_hour, null: false, default: 7
      t.boolean :optimize_automatically, null: false, default: true
      t.integer :optimize_max_height, null: false, default: 1080
      t.integer :optimize_budget_gb, null: false, default: 200
    end
  end
end
