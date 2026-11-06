# typed: false
# frozen_string_literal: true

# Subscriptions (PROPOSAL §5.4): each profile's own channels, whose new
# videos make its feed; and Watch later, a playlist every profile has.
class CreateSubscriptionsAndWatchLater < ActiveRecord::Migration[8.1]
  def change
    create_table :channel_subscriptions, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :channel, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index %i[profile_id channel_id], unique: true
    end

    # A playlist Stream keeps for the profile: "watch_later". Nil for a
    # person's own.
    add_column :playlists, :system_kind, :string
    add_index :playlists, %i[profile_id system_kind], unique: true, where: "system_kind IS NOT NULL"
  end
end
