# typed: false
# frozen_string_literal: true

# Extras (PROPOSAL §4.2): trailers, featurettes, deleted scenes and the
# rest, each one file, attached to a movie, show or season. The owner is
# empty until the title it sits beside has been read.
class CreateExtras < ActiveRecord::Migration[8.1]
  def change
    create_table :extras, id: :uuid do |t|
      t.references :household, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :media_file, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :owner, type: :uuid, polymorphic: true
      t.string :kind, null: false
      t.string :title, null: false
      t.timestamps
    end
  end
end
