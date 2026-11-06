# frozen_string_literal: true

# NBA League Pass (PROPOSAL §7.8): that the household watches on NBA.com,
# which puts Basketball in the sidebar. No account is kept: games open on
# NBA.com, where the person signs in.
class CreateNbaSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :nba_settings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.boolean :last_test_ok
      t.string :last_test_message
      t.datetime :last_tested_at
      t.timestamps
    end
  end
end
