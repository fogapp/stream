# frozen_string_literal: true

# What each rung of the ladder did for a file on a kind of client:
# learned from plays, so a rung that
# failed isn't tried first next time — for the file, and for its format
# once two files of it have failed the same way.
class CreatePlayabilities < ActiveRecord::Migration[8.1]
  def change
    create_table :playabilities, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :format_signature, null: false
      t.string :client_class, null: false
      t.string :rung, null: false
      t.integer :successes, default: 0, null: false
      t.integer :failures, default: 0, null: false
      t.datetime :last_succeeded_at
      t.datetime :last_failed_at
      t.string :last_failure_class
      t.string :last_failure_cause
      t.timestamps
    end
    add_index :playabilities, %i[media_file_id client_class rung], unique: true
    add_index :playabilities, %i[household_id format_signature client_class rung], name: "index_playabilities_on_format"

    add_column :playback_sessions, :client_class, :string
    add_column :playback_sessions, :start_position_seconds, :float
    add_column :playback_sessions, :outcome_recorded_at, :datetime
  end
end
