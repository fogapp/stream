# typed: false
# frozen_string_literal: true

# Live TV's neighbouring channels (PROPOSAL §7.7) are tuned ahead of time so
# changing channel is instant. Until someone switches to one, its session is
# on standby: not a play, not "now playing", not in Stats.
class AddStandbyToPlaybackSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :playback_sessions, :standby, :boolean, null: false, default: false
  end
end
