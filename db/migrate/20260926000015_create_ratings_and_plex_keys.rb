# typed: false
# frozen_string_literal: true

# Plex migration, part 2 (PROPOSAL §7.4): each profile's star ratings, and
# which Plex collection a Stream one came from, so a second import updates
# it rather than making another.
class CreateRatingsAndPlexKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :ratings, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :rateable, type: :uuid, polymorphic: true, null: false
      # Out of 10, as Plex and TMDB keep them; the stars are halves of it.
      t.float :value, null: false
      t.datetime :rated_at, null: false
      t.timestamps
      t.index %i[profile_id rateable_type rateable_id], unique: true, name: "index_ratings_uniqueness"
    end

    add_column :collections, :plex_key, :string
    add_index :collections, %i[household_id plex_key], unique: true, where: "plex_key IS NOT NULL"
  end
end
