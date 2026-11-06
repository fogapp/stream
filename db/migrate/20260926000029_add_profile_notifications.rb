# typed: false
# frozen_string_literal: true

# ntfy for each profile (PROPOSAL §7.4): "new episode of X" and new videos
# from its subscriptions, to its own topic; and the ntfy server itself,
# set in Settings rather than by environment.
class AddProfileNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :ntfy_url, :string
    add_column :profiles, :ntfy_topic, :string
    add_column :profiles, :notify_new_episodes, :boolean, null: false, default: true
    add_column :profiles, :notify_subscriptions, :boolean, null: false, default: true

    # What each profile has been told about, so nothing is told twice.
    create_table :profile_notices, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :subject, type: :uuid, polymorphic: true, null: false
      t.datetime :created_at, null: false
      t.index %i[profile_id subject_type subject_id], unique: true, name: "index_profile_notices_uniqueness"
    end
  end
end
