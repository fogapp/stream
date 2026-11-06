# frozen_string_literal: true

# The Playback page's optimize controls: why each version is queued (an
# admin asked, no device plays the file, a Live TV airing, the next
# episode), "do next" (prioritized_at), what last stopped an encode part
# way, and a switch to pause optimizing altogether.
class AddQueueControlsToOptimizedVersions < ActiveRecord::Migration[8.1]
  def change
    change_table :optimized_versions, bulk: true do |t|
      t.string :reason
      t.datetime :prioritized_at
      t.integer :interruptions, default: 0, null: false
      t.datetime :interrupted_at
      t.string :interruption
    end
    add_column :app_settings, :optimize_paused, :boolean, default: false, null: false

    reversible do |direction|
      # Automatic ones are stamped by the next hourly pass.
      direction.up { execute "UPDATE optimized_versions SET reason = 'manual' WHERE origin = 'manual'" }
    end
  end
end
