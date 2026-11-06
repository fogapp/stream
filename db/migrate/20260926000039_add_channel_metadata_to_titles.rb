# typed: false
# frozen_string_literal: true

# What Live TV channels choose by: every network a show aired on (not just
# the first), the studios behind a film, and TMDB's keywords for both
# ("christmas", "sitcom", "slasher"). Filled on the next metadata refresh.
class AddChannelMetadataToTitles < ActiveRecord::Migration[8.1]
  def change
    add_column :shows, :networks, :string, array: true, default: [], null: false
    add_column :shows, :keywords, :string, array: true, default: [], null: false
    add_column :movies, :studios, :string, array: true, default: [], null: false
    add_column :movies, :keywords, :string, array: true, default: [], null: false
    add_index :shows, :networks, using: :gin
    add_index :shows, :keywords, using: :gin
    add_index :movies, :studios, using: :gin
    add_index :movies, :keywords, using: :gin

    reversible do |dir|
      dir.up { execute "UPDATE shows SET networks = ARRAY[network] WHERE network IS NOT NULL" }
    end
  end
end
