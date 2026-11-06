# typed: false
# frozen_string_literal: true

# SponsorBlock (PROPOSAL §5.4): the community's segments for a YouTube
# video — sponsor reads, self-promotion, "like and subscribe" — frozen
# here, opt-in per library, skipped or offered per profile.
class CreateSponsorSegments < ActiveRecord::Migration[8.1]
  def change
    create_table :sponsor_segments, id: :uuid do |t|
      t.references :video, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :category, null: false
      t.float :start_seconds, null: false
      t.float :end_seconds, null: false
      t.string :uuid, null: false
      t.timestamps
      t.index %i[video_id uuid], unique: true
    end

    add_column :videos, :sponsorblock_checked_at, :datetime
    add_column :libraries, :sponsorblock, :boolean, null: false, default: false
    # { category => "skip" | "ask" | "show" } for this profile; unset uses the default.
    add_column :profiles, :sponsorblock, :jsonb, null: false, default: {}
  end
end
