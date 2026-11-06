# typed: false
# frozen_string_literal: true

# Live TV (PROPOSAL §7.7): channels made from the library. A station is the
# channel; its blocks are the layered rules that program it; airings are the
# schedule those rules produced, fixed three days ahead. Named Station
# because YouTube's channels already own `channels`.
class CreateStations < ActiveRecord::Migration[8.1]
  def change
    create_table :stations, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :number, null: false
      t.integer :number_major, null: false
      t.integer :number_minor, null: false, default: 0
      t.string :name, null: false
      t.string :call_sign
      t.integer :snap_minutes, null: false, default: 0
      t.integer :no_repeat_days, null: false, default: 3
      t.datetime :scheduled_through
      t.datetime :last_scheduled_at
      t.string :last_error
      t.timestamps
    end
    add_index :stations, %i[household_id number], unique: true
    add_index :stations, %i[household_id number_major number_minor]

    create_table :station_blocks, id: :uuid do |t|
      t.references :station, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :layer, null: false
      t.string :name
      t.integer :days, null: false, default: 127
      t.integer :start_minute
      t.integer :end_minute
      t.date :starts_on
      t.date :ends_on
      t.jsonb :source, null: false, default: {}
      t.string :ordering, null: false, default: "shuffle"
      t.integer :marathon_length, null: false, default: 3
      t.boolean :loops, null: false, default: true
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :airings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :station, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :station_block, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :playable, type: :uuid, polymorphic: true, null: false
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :series_key, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :reason, null: false
      t.datetime :created_at, null: false
    end
    add_index :airings, %i[station_id starts_at], unique: true
    add_index :airings, %i[station_id ends_at]
    add_index :airings, %i[station_block_id series_key starts_at]

    create_table :station_hides, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :station, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :created_at, null: false
    end
    add_index :station_hides, %i[profile_id station_id], unique: true

    add_reference :playback_sessions, :airing, type: :uuid, foreign_key: { on_delete: :nullify }
    add_column :playback_sessions, :joined_at_seconds, :float
  end
end
