# frozen_string_literal: true

# A show can be filed from more than one folder ("Bluey" and "Bluey (2018)"):
# each folder is a row, and the scanner finds a show by its folder here.
# `shows.folder` stays as the show's first folder, which old code still reads
# during a blue-green swap.
class CreateShowFolders < ActiveRecord::Migration[8.1]
  def up
    create_table :show_folders, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :show, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :folder, null: false
      t.timestamps
    end
    add_index :show_folders, %i[library_id folder], unique: true

    execute <<~SQL.squish
      INSERT INTO show_folders (household_id, library_id, show_id, folder, created_at, updated_at)
      SELECT household_id, library_id, id, folder, created_at, created_at FROM shows
    SQL
  end

  def down
    drop_table :show_folders
  end
end
