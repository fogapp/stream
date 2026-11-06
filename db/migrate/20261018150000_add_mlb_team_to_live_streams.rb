# frozen_string_literal: true

# A team's MLB.tv broadcast as a stream of its own (PROPOSAL §7.8): whatever
# game the team is playing, made the first time someone watches it from
# Baseball or puts it on a Grid channel. It belongs to no library.
class AddMlbTeamToLiveStreams < ActiveRecord::Migration[8.1]
  def change
    add_column :live_streams, :mlb_team_id, :integer
    change_column_null :live_streams, :library_id, true
    add_index :live_streams, %i[household_id mlb_team_id], unique: true, where: "mlb_team_id IS NOT NULL"
  end
end
