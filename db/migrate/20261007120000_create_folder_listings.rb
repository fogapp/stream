# frozen_string_literal: true

# What Libraries::ChangeDetector last saw in one library root: the folders a
# scan would start from, each with its mtime. A row of its own, not a column
# on libraries, so the few thousand entries of a shows root aren't read with
# every library.
class CreateFolderListings < ActiveRecord::Migration[8.1]
  def change
    create_table :folder_listings, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :root, null: false
      t.jsonb :entries, null: false, default: {}
      t.timestamps
    end
    add_index :folder_listings, %i[library_id root], unique: true
  end
end
