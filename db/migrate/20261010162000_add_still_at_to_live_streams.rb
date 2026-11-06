# frozen_string_literal: true

# When a live stream's card picture was last taken (LiveStreams::Still): its
# URL's version, so a new picture is a new URL.
class AddStillAtToLiveStreams < ActiveRecord::Migration[8.1]
  def change
    add_column :live_streams, :still_at, :datetime
  end
end
