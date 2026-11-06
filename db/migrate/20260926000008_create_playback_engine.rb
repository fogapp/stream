# typed: false
# frozen_string_literal: true

# The playback engine (PROPOSAL §4.4, §6): the browsers and TVs that play,
# with the capability profile each last reported; what a session chose and
# why; and what happened while it played.
class CreatePlaybackEngine < ActiveRecord::Migration[8.1]
  def change
    create_table :devices, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # Minted by the client and kept in its storage: the same browser is
      # the same device across sign-ins.
      t.string :client_key, null: false
      t.string :name, null: false
      t.jsonb :capabilities, null: false, default: {}
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[household_id client_key], unique: true
    end

    # The Phase 1 user-agent label makes way for the device association.
    rename_column :playback_sessions, :device, :device_name

    change_table :playback_sessions, bulk: true do |t|
      t.references :device, type: :uuid, foreign_key: { on_delete: :nullify }
      t.integer :audio_stream_index
      # The transcoder's view of the session: where its ffmpeg run started,
      # when it last produced anything, and why it stopped if it failed.
      t.integer :run_start
      t.datetime :run_started_at
      t.string :transcode_error
    end

    create_table :playback_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :playback_session, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # start, seek, stall, error, stop
      t.string :kind, null: false
      t.float :position_seconds
      t.jsonb :detail, null: false, default: {}
      t.datetime :created_at, null: false
      t.index %i[playback_session_id created_at]
    end

    # Simultaneous video transcodes this machine will run. nil: decided by
    # the encoder probe (1 in software, more with a hardware encoder).
    add_column :app_settings, :max_video_transcodes, :integer
  end
end
