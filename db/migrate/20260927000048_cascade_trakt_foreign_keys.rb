# typed: false
# frozen_string_literal: true

# Trakt's rows go with their household and profile, as every other
# household table's do: removing a household (e2e:clean, a restore) was
# refused while a Trakt setting or link remained.
class CascadeTraktForeignKeys < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :trakt_settings, :households
    add_foreign_key :trakt_settings, :households, on_delete: :cascade
    remove_foreign_key :trakt_accounts, :households
    add_foreign_key :trakt_accounts, :households, on_delete: :cascade
    remove_foreign_key :trakt_accounts, :profiles
    add_foreign_key :trakt_accounts, :profiles, on_delete: :cascade
  end
end
