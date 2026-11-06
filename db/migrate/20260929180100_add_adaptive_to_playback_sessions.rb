# frozen_string_literal: true

# Whether a stream offers smaller versions of itself (Playback::Variants):
# off the household's network, or where a browser asked for it. On the LAN
# nothing ever needs them, and a player that can't tell a slow transcoder
# from a slow network drops to one and starts a second ffmpeg for it
# (docs/PERF_PROPOSAL.md › P8).
class AddAdaptiveToPlaybackSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :playback_sessions, :adaptive, :boolean, default: false, null: false
  end
end
