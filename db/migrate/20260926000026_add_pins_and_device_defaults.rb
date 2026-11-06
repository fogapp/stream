# typed: false
# frozen_string_literal: true

# Profiles for a whole household (PROPOSAL §7.4): an optional PIN, an avatar,
# and a default profile per device so the living-room TV skips the picker.
class AddPinsAndDeviceDefaults < ActiveRecord::Migration[8.1]
  def change
    add_column :profiles, :pin_digest, :string
    # Bumped when the PIN changes, so a profile token minted before stops working.
    add_column :profiles, :pin_changed_at, :datetime
    # An emoji, or nil for the name's initial on the colour.
    add_column :profiles, :avatar, :string
    add_reference :devices, :default_profile, type: :uuid, foreign_key: { to_table: :profiles, on_delete: :nullify }
  end
end
