# typed: false
# frozen_string_literal: true

# Recommendations (PROPOSAL §7.1): each title as a vector of what it's
# made of — genres, people, series, era, words — so "more like this" is a
# nearest-neighbour search in Postgres, with nothing sent anywhere. And
# smart collections: a saved set of rules instead of a list.
class CreateRecommendationsAndSmartCollections < ActiveRecord::Migration[8.1]
  def change
    enable_extension "vector"

    add_column :movies, :embedding, :vector, limit: 512
    add_column :movies, :embedded_at, :datetime
    add_column :shows, :embedding, :vector, limit: 512
    add_column :shows, :embedded_at, :datetime
    add_index :movies, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    add_index :shows, :embedding, using: :hnsw, opclass: :vector_cosine_ops

    add_column :collections, :rules, :jsonb, null: false, default: {}
  end
end
