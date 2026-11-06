# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  let(:household) { Household.create!(name: "H") }

  it "normalizes email on the way in" do
    user = household.users.create!(email: "  Matt@Example.COM ", name: "M", password: "passwordpassword")
    expect(user.email).to eq("matt@example.com")
  end

  it "requires a password of at least ten characters" do
    user = household.users.build(email: "a@b.co", name: "A", password: "short")
    expect(user).not_to be_valid
    expect(user.errors[:password]).to be_present
  end

  it "knows who is an admin" do
    admin = household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword", role: "admin")
    member = household.users.create!(email: "m@b.co", name: "M", password: "passwordpassword")
    expect(admin).to be_admin
    expect(member).not_to be_admin
  end

  it "takes its sessions and notifications along when destroyed" do
    user = household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword")
    ApiSession.generate!(user: user)
    Notification.create!(user: user, household: household, kind: "k", title: "t", dedupe_key: "d")

    user.destroy!

    expect(ApiSession.where(user_id: user.id)).not_to exist
    expect(Notification.where(user_id: user.id)).not_to exist
  end
end
