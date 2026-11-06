# frozen_string_literal: true

# A live stream's play (PROPOSAL §7.8) has no file: the session's playable
# is the LiveStream, and its relay reads the stream's own address.
class LiveStreamSessions < ActiveRecord::Migration[8.1]
  def change
    change_column_null :playback_sessions, :media_file_id, true
  end
end
