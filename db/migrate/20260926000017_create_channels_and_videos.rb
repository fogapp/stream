# typed: false
# frozen_string_literal: true

# The channel shape (PROPOSAL §4.2, §5.4): a channel's videos, read from
# yt-dlp's info.json, an NFO, or just the folder they sit in.
class CreateChannelsAndVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :channels, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # The channel's folder under the library root: what its videos share.
      t.string :folder, null: false
      t.string :youtube_id
      t.string :handle
      t.string :title, null: false
      t.string :sort_title, null: false
      t.text :description
      t.string :url
      t.string :locked_fields, array: true, null: false, default: []
      t.timestamps
      t.index %i[library_id folder], unique: true
      t.index %i[household_id youtube_id]
      t.index :title, using: :gin, opclass: :gin_trgm_ops, name: "index_channels_on_title_trgm"
    end

    create_table :videos, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :channel, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :youtube_id
      t.string :title, null: false
      t.string :sort_title, null: false
      t.text :description
      t.date :upload_date
      t.string :tags, array: true, null: false, default: []
      # From info.json when the file carries none: [{ start, end, title }].
      t.jsonb :chapters, null: false, default: []
      t.string :url
      # Where the details came from: info_json, nfo, tags or folder.
      t.string :source, null: false
      t.string :locked_fields, array: true, null: false, default: []
      t.timestamps
      t.index %i[library_id youtube_id], unique: true, where: "youtube_id IS NOT NULL"
      t.index %i[channel_id upload_date]
      t.index :title, using: :gin, opclass: :gin_trgm_ops, name: "index_videos_on_title_trgm"
    end
  end
end
