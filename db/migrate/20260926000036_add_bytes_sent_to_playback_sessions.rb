# typed: false
# frozen_string_literal: true

# What actually went over the network for a session (PROPOSAL §7.4): the
# bytes each media request asked for, counted as Rails authorizes it.
class AddBytesSentToPlaybackSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :playback_sessions, :bytes_sent, :bigint, null: false, default: 0
  end
end
