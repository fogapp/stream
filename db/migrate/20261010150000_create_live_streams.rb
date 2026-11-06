# frozen_string_literal: true

# Live streams (PROPOSAL §7.8): a camera or a web stream an admin added by
# URL, in a library of the live kind. Its tracks are MediaStream rows and its
# probe an AnalysisRun, exactly as a file's are, so those tables now belong
# to a file or a live stream — one, never both.
class CreateLiveStreams < ActiveRecord::Migration[8.1]
  def change
    create_table :live_streams, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :sort_title, null: false
      t.string :kind, null: false
      # Encrypted: a camera's secret is its credentials or its path.
      t.text :url, null: false
      t.boolean :trust_certificate, default: false, null: false
      t.text :description
      t.string :content_rating
      t.integer :rating_age
      t.string :status, default: "online", null: false
      t.datetime :last_seen_at
      t.string :last_error
      t.datetime :last_error_at
      t.integer :consecutive_failures, default: 0, null: false
      t.string :container
      t.datetime :probed_at
      t.timestamps
    end
    add_index :live_streams, %i[library_id sort_title]

    change_column_null :media_streams, :media_file_id, true
    add_reference :media_streams, :live_stream, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
    add_index :media_streams, %i[live_stream_id index], unique: true, where: "live_stream_id IS NOT NULL"
    add_check_constraint :media_streams, "num_nonnulls(media_file_id, live_stream_id) = 1", name: "media_streams_one_owner"

    change_column_null :analysis_runs, :media_file_id, true
    add_reference :analysis_runs, :live_stream, type: :uuid, foreign_key: { on_delete: :cascade }, index: false
    add_index :analysis_runs, %i[live_stream_id step], unique: true, where: "live_stream_id IS NOT NULL"
    add_check_constraint :analysis_runs, "num_nonnulls(media_file_id, live_stream_id) = 1", name: "analysis_runs_one_owner"
  end
end
