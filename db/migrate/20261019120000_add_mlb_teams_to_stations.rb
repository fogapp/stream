# frozen_string_literal: true

# A Grid channel can carry teams' games (PROPOSAL §7.7, §7.8): whenever one
# of its clubs plays, the game is on the schedule, the library's programming
# around it. A game's airing plays the team's MLB.tv stream, so it has no
# file; it keeps which game it is and what the guide calls it.
class AddMlbTeamsToStations < ActiveRecord::Migration[8.1]
  def change
    add_column :stations, :mlb_team_ids, :integer, array: true, default: [], null: false
    change_column_null :airings, :media_file_id, true
    add_column :airings, :mlb_game_pk, :integer
    add_column :airings, :program_title, :string
    add_column :airings, :program_subtitle, :string
  end
end
