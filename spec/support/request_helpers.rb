# typed: false
# frozen_string_literal: true

# Hand-rolled fixture helpers, no FactoryBot (hub convention:
# hub:spec/support/request_helpers.rb).
module RequestHelpers
  def create_household(name: "Test Household")
    Household.create!(name: name)
  end

  def create_user(household:, email: nil, role: "member", password: "passwordpassword")
    household.users.create!(
      email: email || "user-#{SecureRandom.hex(4)}@example.com",
      name: "Test User",
      password: password,
      role: role
    )
  end

  def auth_headers(user, device: "spec")
    session = ApiSession.generate!(user: user, device: device)
    { "Authorization" => "Bearer #{session.token}" }
  end

  # Watching as a profile: the signed token a browser gets by choosing it.
  def profile_header(profile) = { "X-Stream-Profile" => ProfileTokens.issue(profile) }

  def json
    JSON.parse(response.body)
  end
end

RSpec.configure do |config|
  config.include RequestHelpers, type: :request
end
