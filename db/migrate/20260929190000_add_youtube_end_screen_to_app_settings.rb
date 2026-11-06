# frozen_string_literal: true

# Settings › YouTube › End screen (PROPOSAL §5.4): whether a finished video
# offers one more from its channel and a few from others. On unless turned off.
class AddYoutubeEndScreenToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :youtube_end_screen, :boolean, default: true, null: false
  end
end
