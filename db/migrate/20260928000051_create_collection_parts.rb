# typed: false
# frozen_string_literal: true

# A TMDB collection's films, whether or not a library has them (PROPOSAL
# §4.2), so a collection shows the whole series with what's missing faded.
class CreateCollectionParts < ActiveRecord::Migration[8.1]
  def change
    create_table :collection_parts, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :collection, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :tmdb_id, null: false
      t.string :title, null: false
      t.date :release_date
      t.text :overview
      t.string :poster_path
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :collection_parts, %i[collection_id tmdb_id], unique: true
  end
end
