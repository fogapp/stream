# frozen_string_literal: true

# A live stream relayed all the time (PROPOSAL §7.8), so pressing play joins
# a relay that's already running: a camera's first picture otherwise waits
# for its next keyframe, five seconds on UniFi's default.
class AddKeepConnectedToLiveStreams < ActiveRecord::Migration[8.1]
  def change
    add_column :live_streams, :keep_connected, :boolean, default: false, null: false
  end
end
