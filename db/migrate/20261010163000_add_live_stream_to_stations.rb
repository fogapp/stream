# frozen_string_literal: true

# A Live TV channel that shows a camera or web stream (PROPOSAL §7.8)
# instead of programming from the library: one program, the stream, all
# day. Removing the stream leaves the channel, with nothing on.
class AddLiveStreamToStations < ActiveRecord::Migration[8.1]
  def change
    add_reference :stations, :live_stream, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
