# typed: false
# frozen_string_literal: true

# The household's wall clock, set in Settings › General rather than by env
# var: a channel's Sunday 8pm (Live TV) is 8pm here, through daylight saving.
class AddTimeZoneToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :time_zone, :string
  end
end
