# frozen_string_literal: true

# A film's title as Catalog::FileMatcher compares titles
# (Media::NameParser.normalize), kept on the row so finding the film a file
# belongs to is a lookup rather than reading every film of that year (or of
# the library, for an extra) to compare in Ruby. Movie sets it before each
# save; this fills it for the films already there, with the same Ruby.
#
# Nullable: a replica still on the old code during the swap writes films
# without it, and the matcher still reads those the old way.
class AddNormalizedTitleToMovies < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  class Film < ActiveRecord::Base
    self.table_name = "movies"
  end

  def up
    add_column :movies, :normalized_title, :string, if_not_exists: true
    Film.where(normalized_title: nil).in_batches(of: 1000) do |batch|
      rows = batch.pluck(:id, :title).map { |id, title| { id: id, normalized_title: Media::NameParser.normalize(title.to_s) } }
      rows.each_slice(1000) do |slice|
        values = slice.map { |row| "(#{connection.quote(row[:id])}::uuid, #{connection.quote(row[:normalized_title])})" }.join(", ")
        execute("UPDATE movies SET normalized_title = v.title FROM (VALUES #{values}) AS v(id, title) WHERE movies.id = v.id")
      end
    end
    add_index :movies, %i[library_id normalized_title], algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :movies, %i[library_id normalized_title], algorithm: :concurrently, if_exists: true
    remove_column :movies, :normalized_title, if_exists: true
  end
end
