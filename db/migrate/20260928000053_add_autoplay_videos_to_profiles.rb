# typed: false
# frozen_string_literal: true

# A profile's choice to have a video start the moment its page opens
# (PROPOSAL §5.4), replacing whatever is playing, muted if the browser
# insists.
class AddAutoplayVideosToProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :profiles, :autoplay_videos, :boolean, default: false, null: false
  end
end
