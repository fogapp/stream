# frozen_string_literal: true

# When TMDB was last asked for a title's trailer. A title it has none for
# leaves no Trailer row, so without this the daily pass asks about the same
# few for ever and never reaches the ones behind them.
class AddTrailerCheckedAtToTitles < ActiveRecord::Migration[8.1]
  def change
    add_column :movies, :trailer_checked_at, :datetime
    add_column :shows, :trailer_checked_at, :datetime
  end
end
