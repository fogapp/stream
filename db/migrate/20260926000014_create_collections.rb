# typed: false
# frozen_string_literal: true

# Collections (PROPOSAL §4.2): TMDB's ("The Alien Collection"), made from
# the films that name one, and a household's own, made by hand. Either
# holds movies and shows in an order.
class CreateCollections < ActiveRecord::Migration[8.1]
  def change
    create_table :collections, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :title, null: false
      t.string :sort_title, null: false
      t.text :overview
      t.integer :tmdb_id
      t.string :poster_path
      t.string :backdrop_path
      t.string :locked_fields, array: true, null: false, default: []
      t.datetime :metadata_refreshed_at
      t.timestamps
      t.index %i[household_id tmdb_id], unique: true, where: "tmdb_id IS NOT NULL"
      t.index :title, using: :gin, opclass: :gin_trgm_ops, name: "index_collections_on_title_trgm"
    end

    create_table :collection_items, id: :uuid do |t|
      t.references :collection, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :item, type: :uuid, polymorphic: true, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index %i[collection_id item_type item_id], unique: true, name: "index_collection_items_uniqueness"
    end
  end
end
