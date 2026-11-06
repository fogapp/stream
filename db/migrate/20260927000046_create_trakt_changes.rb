# typed: false
# frozen_string_literal: true

# What a linked profile did in Stream that Trakt hasn't heard yet (PROPOSAL
# §7.4): an outbox, drained by TraktPushJob, so a Trakt outage delays a
# change rather than losing it.
class CreateTraktChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :trakt_changes, id: :uuid do |t|
      t.references :trakt_account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :action, null: false
      t.string :item_type, null: false
      t.uuid :item_id, null: false
      t.datetime :watched_at
      t.integer :rating
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.datetime :created_at, null: false
    end
    add_index :trakt_changes, %i[trakt_account_id created_at]
  end
end
