# frozen_string_literal: true

# Which YouTube video a video on disk is (Youtube::Identifier): videos put in
# a channel's folder by hand arrive with no id, and are looked up by title
# and length. Candidates the lookup wasn't sure of wait here for a person.
class AddIdentityToVideos < ActiveRecord::Migration[8.1]
  def up
    add_column :videos, :identity, :string, null: false, default: "unchecked"
    add_column :videos, :youtube_candidates, :jsonb, null: false, default: []
    add_column :videos, :thumbnail_url, :string
    execute "UPDATE videos SET identity = 'identified' WHERE youtube_id IS NOT NULL"
    add_index :videos, %i[channel_id identity]
  end

  def down
    remove_index :videos, %i[channel_id identity]
    remove_column :videos, :thumbnail_url
    remove_column :videos, :youtube_candidates
    remove_column :videos, :identity
  end
end
