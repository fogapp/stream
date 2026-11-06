# typed: false
# frozen_string_literal: true

# Remote control (PROPOSAL §11 Phase 6: "play the next episode of Severance
# in the living room"): a device people can play to has a name for it, and
# picks up commands — play this, pause, carry on — on its next poll.
class CreateDeviceCommands < ActiveRecord::Migration[8.1]
  def change
    change_table :devices, bulk: true do |t|
      # What the household calls it ("Living room"); name stays the browser.
      t.string :label
      # Whether it can be played to, and when it last asked for commands.
      t.boolean :remote_control, null: false, default: false
      t.datetime :remote_seen_at
    end

    create_table :device_commands, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :device, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :kind, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :delivered_at
      t.datetime :expires_at, null: false
      t.timestamps
      t.index %i[device_id delivered_at]
    end
  end
end
