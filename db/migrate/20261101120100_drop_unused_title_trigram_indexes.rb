# frozen_string_literal: true

# Trigram indexes on the bare column, which no query can use: search and the
# grids match unaccent(title) and call word_similarity() (EXPLAIN, 2026-11-01:
# a filter over the household's rows, on any size of library). Every title
# saved paid for them. An index that could serve search needs an immutable
# unaccent wrapper, and search needs none: it's a household's titles, a few
# times a week.
#
# Concurrently, so no write waits on a table a scan is filling.
class DropUnusedTitleTrigramIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = {
    movies: :title, shows: :title, episodes: :title, collections: :title, channels: :title, videos: :title, people: :name
  }.freeze

  def up
    INDEXES.each { |table, column| remove_index table, name: "index_#{table}_on_#{column}_trgm", algorithm: :concurrently, if_exists: true }
  end

  def down
    INDEXES.each do |table, column|
      add_index table, column, using: :gin, opclass: :gin_trgm_ops, name: "index_#{table}_on_#{column}_trgm", algorithm: :concurrently, if_not_exists: true
    end
  end
end
