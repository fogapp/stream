# typed: false
# frozen_string_literal: true

# Trakt (PROPOSAL §7.4): the household registers one Trakt API app, and each
# adult profile links its own Trakt account to it with a device code.
class CreateTrakt < ActiveRecord::Migration[8.1]
  def change
    create_table :trakt_settings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :client_id, null: false
      t.text :client_secret, null: false
      t.datetime :last_tested_at
      t.boolean :last_test_ok
      t.string :last_test_message
      t.timestamps
    end

    create_table :trakt_accounts, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: true
      t.references :profile, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :state, null: false, default: "pending"
      # While linking: what the person types at trakt.tv/activate.
      t.text :device_code
      t.string :user_code
      t.string :verification_url
      t.integer :poll_interval
      t.datetime :device_expires_at
      t.datetime :polled_at
      # Once linked.
      t.string :username
      t.text :access_token
      t.text :refresh_token
      t.datetime :expires_at
      t.datetime :linked_at
      t.datetime :last_synced_at
      t.jsonb :last_activities, null: false, default: {}
      t.jsonb :synced_keys, null: false, default: {}
      t.string :last_error
      t.datetime :last_error_at
      t.timestamps
    end
  end
end
