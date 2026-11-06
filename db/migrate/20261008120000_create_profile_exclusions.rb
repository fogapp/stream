# frozen_string_literal: true

# What a profile has hidden from itself (Viewing::Access): a movie, show or
# YouTube channel marked here appears nowhere on that profile.
class CreateProfileExclusions < ActiveRecord::Migration[8.1]
  def change
    create_table :profile_exclusions, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :excludable, type: :uuid, polymorphic: true, null: false
      t.timestamps
      t.index %i[profile_id excludable_type excludable_id], unique: true, name: "index_profile_exclusions_uniqueness"
    end
  end
end
