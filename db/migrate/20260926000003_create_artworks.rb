# typed: false
# frozen_string_literal: true

# Artwork (PROPOSAL §4.2, §5.5): one row per owner per kind, rendered once
# into WebP at a few widths in the storage volume, with an inline blurred
# placeholder and an average colour so grids paint before the image lands.
class CreateArtworks < ActiveRecord::Migration[8.1]
  def change
    create_table :artworks, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :owner, type: :uuid, polymorphic: true, null: false, index: false
      t.string :kind, null: false
      t.string :source, null: false
      # TMDB image path, or the media file id for a frame grab. A change
      # means a re-render.
      t.string :source_ref, null: false
      # Bumped on every render; part of the URL, so a new render is a new
      # URL and the old one can be cached forever.
      t.integer :version, null: false, default: 0
      t.string :state, null: false, default: "pending"
      t.integer :width
      t.integer :height
      t.integer :rendered_widths, array: true, null: false, default: []
      t.text :placeholder
      t.string :color
      t.string :last_error
      t.integer :consecutive_failures, null: false, default: 0
      t.datetime :rendered_at
      t.timestamps
      t.index %i[owner_type owner_id kind], unique: true
      t.index %i[state updated_at]
    end
  end
end
