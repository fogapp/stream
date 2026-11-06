# typed: false
# frozen_string_literal: true

# Commercial breaks (PROPOSAL §7.7): a channel with filler can break a
# program at its chapters (and after a cold open), so the time until the
# next slot is spent in the middle, as on TV. A program then airs in parts:
# each airing plays its file from media_start to media_end.
class AddBreaksToLiveTv < ActiveRecord::Migration[8.1]
  def change
    add_column :stations, :breaks, :boolean, null: false, default: false
    add_column :airings, :media_start, :float, null: false, default: 0.0
    add_column :airings, :media_end, :float
  end
end
