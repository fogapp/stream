# typed: false
# frozen_string_literal: true

# Kid and curated profiles, and per-profile playback (PROPOSAL §7.4).
class CreateKidProfiles < ActiveRecord::Migration[8.1]
  def up
    change_table :profiles, bulk: true do |t|
      # standard or kid (a kid profile can't reach settings).
      t.string :kind, null: false, default: "standard"
      # The oldest age a title may be rated for (G/TV-Y 0 … R/TV-MA 17); nil = no ceiling.
      t.integer :max_rating_age
      t.boolean :allow_unrated, null: false, default: false
      # Empty: every library.
      t.uuid :library_ids, array: true, null: false, default: []
      # Only what's tagged for this profile.
      t.boolean :curated, null: false, default: false
      # nil: the household's usual countdown.
      t.integer :up_next_seconds
      t.boolean :always_skip_intro, null: false, default: false
      t.boolean :always_skip_credits, null: false, default: false
      # Episodes in a row before "Still watching?"; 0 never asks, nil the usual 3.
      t.integer :still_watching_after
    end

    add_column :movies, :rating_age, :integer
    add_column :shows, :rating_age, :integer

    create_table :profile_tags, id: :uuid do |t|
      t.references :profile, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :taggable, type: :uuid, polymorphic: true, null: false
      t.timestamps
      t.index %i[profile_id taggable_type taggable_id], unique: true, name: "index_profile_tags_uniqueness"
    end

    # What's already here gets its age.
    %w[movies shows].each do |table|
      select_rows("SELECT DISTINCT content_rating FROM #{table} WHERE content_rating IS NOT NULL").flatten.each do |rating|
        age = ContentRatings.age(rating)
        execute(ActiveRecord::Base.sanitize_sql_array([ "UPDATE #{table} SET rating_age = ? WHERE content_rating = ?", age, rating ])) if age
      end
    end
  end

  def down
    drop_table :profile_tags
    remove_column :shows, :rating_age
    remove_column :movies, :rating_age
    change_table :profiles, bulk: true do |t|
      t.remove :kind, :max_rating_age, :allow_unrated, :library_ids, :curated, :up_next_seconds, :always_skip_intro,
        :always_skip_credits, :still_watching_after
    end
  end
end
