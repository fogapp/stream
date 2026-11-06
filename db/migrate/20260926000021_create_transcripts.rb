# typed: false
# frozen_string_literal: true

# Transcripts (PROPOSAL §5.5): what was said, line by line with its time,
# from a file's own subtitles or, for channel videos without any, Whisper.
# Lines carry a tsvector so search can say "…at 12:41 in Video X".
class CreateTranscripts < ActiveRecord::Migration[8.1]
  def change
    create_table :transcripts, id: :uuid do |t|
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # subtitles or whisper
      t.string :source, null: false
      t.string :language
      # The subtitle track it came from, so a changed track rebuilds it.
      t.string :track_id
      t.integer :line_count, null: false, default: 0
      t.timestamps
    end

    create_table :transcript_lines, id: :uuid do |t|
      t.references :transcript, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.float :start_seconds, null: false
      t.float :end_seconds, null: false
      t.text :text, null: false
      t.virtual :tsv, type: :tsvector, as: "to_tsvector('english', text)", stored: true
      t.index :tsv, using: :gin
      t.index %i[media_file_id start_seconds]
    end

    create_table :whisper_settings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :url, null: false
      # asr_webservice (fog's Whisper app) or openai (an OpenAI-compatible server).
      t.string :api_kind, null: false, default: "asr_webservice"
      t.string :model
      t.text :api_key
      t.boolean :enabled, null: false, default: true
      t.boolean :last_test_ok
      t.string :last_test_message
      t.datetime :last_tested_at
      t.timestamps
    end
  end
end
