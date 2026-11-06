# frozen_string_literal: true

# The facts a decision needs that the probe saw and didn't keep:
# interlacing, chroma, rotation, where
# the timeline starts, how sound is sampled, what a stream is for.
class AddProbeFactsToMediaStreams < ActiveRecord::Migration[8.1]
  def change
    change_table :media_streams, bulk: true do |t|
      t.float :start_time
      t.string :field_order
      t.string :sample_aspect_ratio
      t.integer :rotation
      t.integer :sample_rate
      t.string :codec_tag
      t.string :chroma
      t.integer :refs
      t.integer :has_b_frames
      t.boolean :comment, default: false, null: false
      t.boolean :hearing_impaired, default: false, null: false
      t.boolean :visual_impaired, default: false, null: false
    end
    add_column :media_files, :start_time, :float
  end
end
