# frozen_string_literal: true

# A household's probed files walked in id order — the conversion report's
# batches and its cache key — read from one index instead of a 76 ms
# filter per batch (Lucid, 2026-10-10).
class AddHouseholdStateIdIndexToMediaFiles < ActiveRecord::Migration[8.1]
  def change
    add_index :media_files, [ :household_id, :state, :id ]
  end
end
