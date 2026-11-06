# typed: false
# frozen_string_literal: true

# Where a play stands with Trakt's scrobbler (PROPOSAL §7.4): the players
# only report progress, so Stream works out start, pause and stop itself.
class AddTraktScrobbleToPlaybackSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :playback_sessions, :trakt_scrobble, :string
    add_column :playback_sessions, :trakt_scrobbled_at, :datetime
    add_index :playback_sessions, :trakt_scrobble, where: "trakt_scrobble = 'watching'"
  end
end
