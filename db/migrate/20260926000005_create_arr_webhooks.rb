# typed: false
# frozen_string_literal: true

# Sonarr and Radarr tell Stream what they just imported, renamed or deleted
# (PROPOSAL §5.1), so "just added" takes seconds rather than the hourly
# scan. Their paths are as their containers see them; path mappings
# translate them into Stream's.
class CreateArrWebhooks < ActiveRecord::Migration[8.1]
  def change
    create_table :arr_webhooks, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # Deterministically encrypted: the URL carries it, so the row is found by it.
      t.string :token, null: false, index: { unique: true }
      t.datetime :last_received_at
      t.string :last_source
      t.string :last_event
      t.string :last_outcome
      t.timestamps
    end

    create_table :path_mappings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :remote_prefix, null: false
      t.string :local_prefix, null: false
      t.timestamps
      t.index %i[household_id remote_prefix], unique: true
    end
  end
end
