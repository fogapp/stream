# frozen_string_literal: true

# MLB.tv (PROPOSAL §7.8): the household's account, which yt-dlp signs in
# with to find a game's broadcasts, and which home or away broadcast a
# game's live stream plays.
class CreateMlbSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :mlb_settings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :username, null: false
      t.text :password, null: false
      t.boolean :last_test_ok
      t.string :last_test_message
      t.datetime :last_tested_at
      t.timestamps
    end

    add_column :live_streams, :feed, :string
  end
end
