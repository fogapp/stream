# typed: false
# frozen_string_literal: true

# Current attributes leak across examples without an explicit reset —
# HouseholdScoped's default scope, and Viewing::Access's profile, would
# silently filter the next spec's queries.
RSpec.configure do |config|
  config.after { Current.reset }
end
