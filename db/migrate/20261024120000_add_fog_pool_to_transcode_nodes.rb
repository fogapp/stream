# frozen_string_literal: true

# A transcoder fog provides (fog-compute/1): one per pool of machines
# paired with fog, keyed by the pool so fog asking again finds the same
# one. Null for a worker an admin added with a token.
class AddFogPoolToTranscodeNodes < ActiveRecord::Migration[8.1]
  def change
    add_column :transcode_nodes, :fog_pool, :string
    add_index :transcode_nodes, :fog_pool, unique: true, where: "fog_pool IS NOT NULL"
  end
end
