# frozen_string_literal: true

# A download someone marked to keep: the channel's keep-last rule passes it by.
class AddKeptToYoutubeDownloads < ActiveRecord::Migration[8.1]
  def change
    add_column :youtube_downloads, :kept, :boolean, default: false, null: false
  end
end
