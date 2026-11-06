# typed: false
# frozen_string_literal: true

# A collection can belong to one library (PROPOSAL §4.2): the Kids' films'
# collections needn't sit with everyone else's. Without one it's the
# household's, as before.
class AddLibraryToCollections < ActiveRecord::Migration[8.1]
  def change
    add_reference :collections, :library, type: :uuid, foreign_key: { on_delete: :nullify }
  end
end
