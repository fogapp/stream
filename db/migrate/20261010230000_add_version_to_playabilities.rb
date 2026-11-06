# frozen_string_literal: true

# What a playability sweep result was found with (Stream and ffmpeg), so a
# new version tries every format again.
class AddVersionToPlayabilities < ActiveRecord::Migration[8.1]
  def change
    add_column :playabilities, :version, :string
  end
end
