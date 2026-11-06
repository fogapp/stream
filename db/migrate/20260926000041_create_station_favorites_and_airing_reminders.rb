# typed: false
# frozen_string_literal: true

# The guide's own per-profile marks (PROPOSAL §7.7): favourite channels, and
# programs a profile asked to be reminded of before they start.
class CreateStationFavoritesAndAiringReminders < ActiveRecord::Migration[8.1]
  def change
    create_table :station_favorites, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :station, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :created_at, null: false
    end
    add_index :station_favorites, %i[profile_id station_id], unique: true

    create_table :airing_reminders, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :airing, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :notified_at
      t.datetime :created_at, null: false
    end
    add_index :airing_reminders, %i[profile_id airing_id], unique: true
  end
end
