# typed: false
# frozen_string_literal: true

# A tracked channel's title filter (PROPOSAL §5.4): a pattern a video's
# title must match to be fetched. Empty fetches everything the other rules
# allow.
class AddTitleFilterToChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :channels, :title_filter, :string
  end
end
