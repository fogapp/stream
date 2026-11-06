# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebauthnCredential do
  let(:household) { Household.create!(name: "H") }
  let(:user) { household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword") }

  it "needs an external id and a public key, and the id is unique" do
    first = user.webauthn_credentials.create!(external_id: "abc", public_key: "pk", nickname: "Phone")
    expect(first).to be_persisted
    dup = user.webauthn_credentials.build(external_id: "abc", public_key: "pk2")
    expect(dup).not_to be_valid
    expect(user.webauthn_credentials.build(public_key: "pk")).not_to be_valid
  end

  it "goes with its user" do
    user.webauthn_credentials.create!(external_id: "abc", public_key: "pk")
    user.destroy!
    expect(described_class.where(external_id: "abc")).not_to exist
  end
end
