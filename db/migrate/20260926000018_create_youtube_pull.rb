# typed: false
# frozen_string_literal: true

# Pulling from YouTube (PROPOSAL §5.4): the one place Stream acquires media.
# A channels library root can be the download folder; a channel can be
# tracked, with rules for how far back to fetch and how much to keep; each
# video to fetch is a download row that says how it went.
class CreateYoutubePull < ActiveRecord::Migration[8.1]
  def change
    add_column :libraries, :download_root, :string

    change_table :channels, bulk: true do |t|
      t.boolean :tracked, null: false, default: false
      # recent (the newest backfill_count), all, or since (backfill_since).
      t.string :backfill, null: false, default: "recent"
      t.integer :backfill_count, null: false, default: 30
      t.date :backfill_since
      # Delete Stream's own downloads beyond the newest N; nil keeps all.
      t.integer :keep_last
      t.boolean :skip_shorts, null: false, default: true
      t.boolean :skip_live, null: false, default: true
      t.integer :max_height, null: false, default: 1080
      t.integer :poll_every_hours, null: false, default: 6
      t.datetime :last_polled_at
      t.string :last_poll_error
      t.string :avatar_url
      t.string :banner_url
    end

    create_table :youtube_downloads, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :channel, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :youtube_id, null: false
      t.string :title
      t.string :state, null: false, default: "queued"
      t.string :reason
      t.string :last_error
      t.integer :attempts, null: false, default: 0
      t.string :path
      t.bigint :bytes
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[channel_id youtube_id], unique: true
      t.index %i[household_id state]
    end
  end
end
