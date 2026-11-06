# typed: false
# frozen_string_literal: true

# Related videos (PROPOSAL §5.4): a video as a vector of what it's about,
# like movies' and shows' for More like this.
class AddEmbeddingToVideos < ActiveRecord::Migration[8.1]
  def change
    add_column :videos, :embedding, :vector, limit: 512
    add_column :videos, :embedded_at, :datetime
    add_index :videos, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
