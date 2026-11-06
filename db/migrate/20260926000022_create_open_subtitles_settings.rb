# typed: false
# frozen_string_literal: true

# OpenSubtitles (PROPOSAL §5.5): missing subtitle languages for movies and
# episodes, fetched once and kept in storage. Opt-in; an account raises the
# daily download allowance.
class CreateOpenSubtitlesSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :open_subtitles_settings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.text :api_key, null: false
      t.string :username
      t.text :password
      t.string :languages, array: true, null: false, default: [ "en" ]
      t.boolean :enabled, null: false, default: true
      t.boolean :last_test_ok
      t.string :last_test_message
      t.datetime :last_tested_at
      # Where the day's downloads stand, as OpenSubtitles last said.
      t.integer :remaining_downloads
      t.datetime :resets_at
      t.timestamps
    end
  end
end
