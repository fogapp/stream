# typed: false
# frozen_string_literal: true

# The household/auth/observability platform lifted from hook (and feed before
# it). Every table's UUID default is gen_random_uuid() — pgcrypto is declared
# in the fog manifest so a fresh instance can load this schema. unaccent is
# here for title search (PROPOSAL §7.2).
class CreatePlatform < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"
    enable_extension "pg_trgm"
    enable_extension "pgcrypto"
    enable_extension "unaccent"

    create_table :households, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.citext :email, null: false, index: { unique: true }
      t.string :name, null: false
      t.string :password_digest, null: false
      t.string :role, null: false, default: "member"
      t.timestamps
    end

    create_table :api_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :token, null: false, index: { unique: true }
      t.string :device
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :api_tokens, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :prefix, null: false
      t.string :token_digest, null: false, index: { unique: true }
      t.datetime :expires_at
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :webauthn_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :external_id, null: false, index: { unique: true }
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.string :nickname
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :invite_codes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :code, null: false, index: { unique: true }
      t.string :role, null: false, default: "member"
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end

    create_table :app_settings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :webhook_url
      t.timestamps
    end
    add_index :app_settings, "(true)", unique: true, name: "index_app_settings_singleton"

    create_table :activity_entries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :source, null: false
      t.string :event, null: false
      t.string :severity, null: false, default: "info"
      t.string :summary, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :subject_type
      t.uuid :subject_id
      t.uuid :trace_id
      t.integer :duration_ms
      t.datetime :created_at, null: false
      t.index :created_at
      t.index %i[household_id created_at]
      t.index %i[severity created_at]
      t.index %i[subject_type subject_id], name: "index_activity_entries_on_subject"
      t.index :trace_id
    end

    create_table :notifications, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :icon
      t.string :title, null: false
      t.string :path
      t.string :dedupe_key, null: false
      t.datetime :read_at
      t.datetime :created_at, null: false
      t.index %i[user_id dedupe_key], unique: true
      t.index %i[user_id read_at]
      t.index :created_at, where: "(read_at IS NOT NULL)", name: "index_notifications_read_on_created_at"
    end

    create_table :job_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :job_key, null: false
      t.string :status, null: false, default: "queued"
      t.string :trigger, null: false, default: "system"
      t.string :message
      t.text :error
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
      t.index %i[job_key created_at]
      t.index %i[household_id job_key created_at]
      t.index :finished_at, where: "(finished_at IS NOT NULL)"
    end
  end
end
