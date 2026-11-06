# typed: false
# frozen_string_literal: true

# A profile's arrangement of the web sidebar: { order: [keys], hidden: [keys] }.
class AddSidebarToProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :profiles, :sidebar, :jsonb, default: {}, null: false
  end
end
