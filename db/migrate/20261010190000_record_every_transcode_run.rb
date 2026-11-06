# frozen_string_literal: true

# Every ffmpeg run gets a row, not just the ones handed to a remote
# transcoder: what it was, how it ended,
# and what ffmpeg said, kept after the cache that held its log is swept.
class RecordEveryTranscodeRun < ActiveRecord::Migration[8.1]
  def change
    change_column_null :transcode_runs, :transcode_node_id, true
    add_column :transcode_runs, :encoder, :string
    add_column :transcode_runs, :start_gop, :integer
    add_column :transcode_runs, :variant, :integer, default: 0, null: false
    add_column :transcode_runs, :signal, :integer
    add_column :transcode_runs, :failure, :string
    add_index :transcode_runs, :created_at
    add_index :transcode_runs, :failure, where: "failure IS NOT NULL"
  end
end
