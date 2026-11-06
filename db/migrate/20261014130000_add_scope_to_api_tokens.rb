# frozen_string_literal: true

# A token's reach: `full` is its owner's access, as every token had until
# now; `read` may look at everything and change nothing — what fog mints
# for an app that only shows what Stream holds (fog-integration/1).
class AddScopeToApiTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :api_tokens, :scope, :string, null: false, default: "full"
  end
end
