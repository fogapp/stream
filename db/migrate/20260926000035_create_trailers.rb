# typed: false
# frozen_string_literal: true

# Trailers (PROPOSAL §7.1–7.2): the official one TMDB names for a film or a
# show, fetched with yt-dlp into Stream's own storage and played from there
# — the trailer hero on Home, the Trailer button on a title's page — so
# nothing is embedded from YouTube.
class CreateTrailers < ActiveRecord::Migration[8.1]
  def change
    create_table :trailers, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :owner, type: :uuid, polymorphic: true, null: false, index: { unique: true }
      t.string :youtube_id, null: false
      t.string :name
      t.string :state, null: false, default: "queued"
      t.bigint :size
      t.text :error
      t.integer :attempts, null: false, default: 0
      t.datetime :fetched_at
      t.timestamps
    end

    add_column :app_settings, :fetch_trailers, :boolean, null: false, default: true
  end
end
