# typed: false
# frozen_string_literal: true

# A clip's time from a camera-style file name (or Immich's local time) is a
# wall clock where it was taken, not an instant: stored as that clock in
# UTC and shown as-is, never shifted into the viewer's zone.
class AddCapturedFloatingToClips < ActiveRecord::Migration[8.1]
  def change
    add_column :clips, :captured_floating, :boolean, null: false, default: false
  end
end
