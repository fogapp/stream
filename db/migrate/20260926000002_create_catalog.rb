# typed: false
# frozen_string_literal: true

# The cinematic and episodic shapes (PROPOSAL §4.2): movies; shows with
# their seasons and episodes; editions linking each playable to the files
# that hold it; people and credits; and the household's TMDB connection.
#
# External ids live as columns (tmdb_id, imdb_id, tvdb_id) rather than an
# ExternalId table: every row has at most one of each, and the matcher and
# the Plex import both look titles up by them.
class CreateCatalog < ActiveRecord::Migration[8.1]
  def change
    create_table :tmdb_settings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      # A v3 API key or a v4 read access token; encrypted, never serialized.
      t.text :api_key
      t.datetime :last_tested_at
      t.boolean :last_test_ok
      t.string :last_test_message
      t.timestamps
    end

    create_table :movies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :title, null: false
      t.string :original_title
      t.string :sort_title, null: false
      t.integer :year
      t.date :release_date
      t.text :overview
      t.string :tagline
      t.integer :runtime_minutes
      t.string :content_rating
      t.string :genres, array: true, null: false, default: []
      t.float :vote_average
      t.integer :tmdb_id
      t.string :imdb_id
      t.integer :tmdb_collection_id
      t.string :tmdb_collection_name
      t.string :poster_path
      t.string :backdrop_path
      t.string :logo_path
      # How the match went: matched, unmatched (no provider or no candidate),
      # or needs_review (candidates below the threshold). Evidence in match_reasons.
      t.string :match_state, null: false, default: "unmatched"
      t.float :match_score
      t.jsonb :match_reasons, null: false, default: {}
      t.jsonb :match_candidates, null: false, default: []
      t.string :locked_fields, array: true, null: false, default: []
      t.datetime :metadata_refreshed_at
      t.timestamps
      t.index %i[library_id tmdb_id], unique: true, where: "tmdb_id IS NOT NULL"
      t.index %i[household_id imdb_id]
      t.index %i[library_id match_state]
      t.index :sort_title
      t.index "title gin_trgm_ops", using: :gin, name: "index_movies_on_title_trgm"
    end

    create_table :shows, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :library, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # The show's own folder under the library root: the key that groups its
      # episode files before any provider has been asked.
      t.string :folder, null: false
      t.string :title, null: false
      t.string :original_title
      t.string :sort_title, null: false
      t.integer :year
      t.date :first_air_date
      t.text :overview
      t.string :status
      t.string :network
      t.string :content_rating
      t.string :genres, array: true, null: false, default: []
      t.float :vote_average
      t.integer :tmdb_id
      t.string :imdb_id
      t.integer :tvdb_id
      t.string :poster_path
      t.string :backdrop_path
      t.string :logo_path
      t.string :match_state, null: false, default: "unmatched"
      t.float :match_score
      t.jsonb :match_reasons, null: false, default: {}
      t.jsonb :match_candidates, null: false, default: []
      t.string :locked_fields, array: true, null: false, default: []
      t.datetime :metadata_refreshed_at
      t.timestamps
      t.index %i[library_id folder], unique: true
      t.index %i[household_id tvdb_id]
      t.index %i[library_id match_state]
      t.index :sort_title
      t.index "title gin_trgm_ops", using: :gin, name: "index_shows_on_title_trgm"
    end

    create_table :seasons, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :show, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :season_number, null: false
      t.string :title
      t.text :overview
      t.date :air_date
      t.integer :episode_count
      t.string :poster_path
      t.integer :tmdb_id
      t.timestamps
      t.index %i[show_id season_number], unique: true
    end

    create_table :episodes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :show, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :season, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :season_number, null: false
      t.integer :episode_number
      t.string :title
      t.text :overview
      t.date :air_date
      t.integer :runtime_minutes
      t.string :still_path
      t.float :vote_average
      t.integer :tmdb_id
      t.string :locked_fields, array: true, null: false, default: []
      t.timestamps
      t.index %i[show_id season_number episode_number], unique: true, where: "episode_number IS NOT NULL"
      t.index %i[show_id air_date]
    end

    # One row per (file, playable). A file with two episodes has two rows; a
    # movie in 4K and 1080p has two files and two rows.
    create_table :editions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :playable, type: :uuid, polymorphic: true, null: false
      t.string :name
      t.timestamps
      t.index %i[media_file_id playable_type playable_id], unique: true, name: "index_editions_uniqueness"
    end

    create_table :people, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.integer :tmdb_id, null: false, index: { unique: true }
      t.string :name, null: false
      t.string :profile_path
      t.timestamps
    end

    create_table :credits, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :person, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :creditable, type: :uuid, polymorphic: true, null: false
      t.string :role, null: false
      t.string :character
      t.string :job
      t.integer :order, null: false, default: 0
      t.timestamps
      t.index %i[creditable_type creditable_id role order], name: "index_credits_listing"
    end
  end
end
