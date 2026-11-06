# frozen_string_literal: true

# fog-integration/1: one row per app fog connected to Stream, naming the API
# token minted for it, so fog can report on and revoke it by the row's id.
class CreateFogIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :fog_integrations, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :api_token, type: :uuid, foreign_key: { on_delete: :nullify }
      # The fog app connected, and which of Stream's offers it took.
      t.string :consumer, null: false
      t.string :offer, null: false
      t.timestamps
    end
  end
end
