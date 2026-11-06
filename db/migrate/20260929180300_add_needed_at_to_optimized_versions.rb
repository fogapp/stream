# frozen_string_literal: true

# When an automatic optimized version will first be wanted
# (docs/PERF_PROPOSAL.md › P20): a Live TV airing's start, or now for the
# next episode of a show someone is watching. The transcoder encodes the
# soonest first, rather than the oldest queued. nil: no hurry.
class AddNeededAtToOptimizedVersions < ActiveRecord::Migration[8.1]
  def change
    add_column :optimized_versions, :needed_at, :datetime
    add_index :optimized_versions, [ :state, :needed_at ]
  end
end
