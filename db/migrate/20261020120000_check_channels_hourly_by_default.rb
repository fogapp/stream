# frozen_string_literal: true

# A newly followed channel is checked for new videos every hour unless it's
# told otherwise. Channels already followed keep what they were given.
class CheckChannelsHourlyByDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :channels, :poll_every_hours, from: 6, to: 1
  end
end
