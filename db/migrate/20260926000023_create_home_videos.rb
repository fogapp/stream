# typed: false
# frozen_string_literal: true

# Home videos (PROPOSAL §4.2, §5.4): a clip per file, grouped by when it was
# taken; albums and people arrive from Immich, which also knows where.
class CreateHomeVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :clips, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :title, null: false
      t.string :sort_title, null: false
      t.datetime :captured_at, null: false
      # Where captured_at came from: immich, metadata, filename or file_date.
      t.string :captured_source, null: false
      t.text :description
      t.string :immich_id
      t.string :city
      t.string :country
      t.float :latitude
      t.float :longitude
      t.boolean :favorite, null: false, default: false
      t.string :locked_fields, array: true, null: false, default: []
      t.timestamps
      t.index %i[library_id captured_at]
      t.index %i[household_id immich_id], unique: true, where: "immich_id IS NOT NULL"
    end

    create_table :albums, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :title, null: false
      t.text :description
      t.string :immich_id
      t.timestamps
      t.index %i[household_id immich_id], unique: true, where: "immich_id IS NOT NULL"
    end

    create_table :album_clips, id: :uuid do |t|
      t.references :album, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :clip, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.index %i[album_id clip_id], unique: true
    end

    # Faces Immich has named, to filter clips by who's in them.
    create_table :home_people, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :immich_id, null: false
      t.string :name, null: false
      t.timestamps
      t.index %i[household_id immich_id], unique: true
    end

    create_table :clip_people, id: :uuid do |t|
      t.references :clip, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :home_person, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.index %i[clip_id home_person_id], unique: true
    end
  end
end
