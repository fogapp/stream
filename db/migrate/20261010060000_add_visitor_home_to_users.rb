# frozen_string_literal: true

# Visitors (fog:docs/signin-proposal.md §10.4): a person from a paired
# household, signed in by their own fog. Their account here carries the fog
# instance they come from; nil is one of this household's own.
class AddVisitorHomeToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :visitor_home, :string
  end
end
