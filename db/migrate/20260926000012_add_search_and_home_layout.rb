# typed: false
# frozen_string_literal: true

# Global search (PROPOSAL §7.2) looks up people and episodes by name with
# typo tolerance, as movies and shows already are; and each profile keeps
# its own order of home hubs (§7.1).
class AddSearchAndHomeLayout < ActiveRecord::Migration[8.1]
  def change
    add_index :people, :name, using: :gin, opclass: :gin_trgm_ops, name: "index_people_on_name_trgm"
    add_index :episodes, :title, using: :gin, opclass: :gin_trgm_ops, name: "index_episodes_on_title_trgm"
    add_column :profiles, :home_layout, :jsonb, null: false, default: {}
  end
end
