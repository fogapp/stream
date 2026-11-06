# typed: false
# frozen_string_literal: true

# What a Live TV channel airs between programs (PROPOSAL §7.7): the slate
# (what's next, and a countdown), or filler — the library's trailers and
# featurettes, or videos from chosen YouTube channels (old adverts,
# station idents) — until the next program starts on the grid.
class AddFillerToStations < ActiveRecord::Migration[8.1]
  def change
    add_column :stations, :filler, :string, null: false, default: "slate"
    add_column :stations, :filler_channel_ids, :uuid, array: true, null: false, default: []
    add_column :airings, :filler, :boolean, null: false, default: false
  end
end
