# frozen_string_literal: true

# A download a person asked for — a pasted video, or one fetched again —
# rather than one a channel's rules chose: the rules don't refuse it.
class AddByHandToYoutubeDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :youtube_downloads, :by_hand, :boolean, null: false, default: false
  end
end
