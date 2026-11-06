# frozen_string_literal: true

# Hook finds a show or a film by its TMDB, TVDB or IMDb id
# (GET /shows?tmdb_id=, /movies?tmdb_id=): each lookup is one index.
class AddExternalIdIndexesToShowsAndMovies < ActiveRecord::Migration[8.1]
  def change
    add_index :shows, %i[household_id tmdb_id]
    add_index :shows, %i[household_id imdb_id]
    add_index :movies, %i[household_id tmdb_id]
  end
end
