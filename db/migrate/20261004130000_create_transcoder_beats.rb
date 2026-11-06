# frozen_string_literal: true

# The transcoder process saying it's alive, every tick, one row per host:
# in Postgres rather than the cache, which isn't shared between processes
# in development.
class CreateTranscoderBeats < ActiveRecord::Migration[8.1]
  def change
    create_table :transcoder_beats, id: :uuid do |t|
      t.string :host, null: false, index: { unique: true }
      t.string :encoder, null: false
      t.boolean :busy, default: false, null: false
      t.datetime :seen_at, null: false
      t.timestamps
    end
  end
end
