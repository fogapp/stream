# typed: false
# frozen_string_literal: true

# Signing a TV in without typing a password on it (PROPOSAL §7.4): the TV
# shows a short code, someone signed in on a phone enters it, and the TV's
# poll picks up a session made for it.
class CreateDevicePairings < ActiveRecord::Migration[8.1]
  def change
    create_table :device_pairings, id: :uuid do |t|
      t.string :code, null: false
      # What the TV polls with; the code alone never hands over a session.
      t.string :poll_token, null: false
      t.string :state, null: false, default: "pending"
      t.references :household, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, foreign_key: { on_delete: :cascade }
      # The session made for the TV, held (encrypted) until it collects it.
      t.text :session_token
      t.string :device_label
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :poll_token, unique: true
      t.index :code, unique: true, where: "state = 'pending'"
    end
  end
end
