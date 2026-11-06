# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiToken do
  let(:household) { Household.create!(name: "H") }
  let(:user) { household.users.create!(email: "a@b.co", name: "A", password: "passwordpassword") }

  describe ".generate" do
    it "mints a prefixed token, stores only its digest, and returns the plaintext once" do
      generated = described_class.generate(user: user, name: "Claude")

      expect(generated.api_token).to be_persisted
      expect(generated.token).to start_with(ApiToken::PREFIX)
      expect(generated.token.length).to eq(ApiToken::PREFIX.length + ApiToken::TOKEN_BYTES * 2)
      expect(generated.api_token.token_digest).to eq(Digest::SHA256.hexdigest(generated.token))
      expect(generated.api_token.prefix).to eq(generated.token.first(ApiToken::DISPLAY_PREFIX_LENGTH))
      expect(generated.api_token.attributes.values).not_to include(generated.token)
    end

    it "returns an unpersisted record with errors instead of raising on a bad name" do
      generated = described_class.generate(user: user, name: "")
      expect(generated.api_token).not_to be_persisted
      expect(generated.api_token.errors[:name]).to be_present
    end

    it "takes an expiry" do
      generated = described_class.generate(user: user, name: "script", expires_at: 1.day.from_now)
      expect(generated.api_token.expires_at).to be_within(1.second).of(1.day.from_now)
    end
  end

  describe ".authenticate" do
    it "finds a live token by its plaintext" do
      generated = described_class.generate(user: user, name: "Claude")
      expect(described_class.authenticate(generated.token)).to eq(generated.api_token)
    end

    it "ignores expired tokens" do
      generated = described_class.generate(user: user, name: "old", expires_at: 1.minute.ago)
      expect(described_class.authenticate(generated.token)).to be_nil
      expect(generated.api_token).to be_expired
    end

    it "answers nil without a query for anything that is not an API token" do
      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate("session-token")).to be_nil
      expect(described_class.authenticate("stream_definitelynotminted")).to be_nil
    end
  end

  describe "#record_use!" do
    it "stamps at most once an hour" do
      token = described_class.generate(user: user, name: "x").api_token
      token.record_use!
      first = token.reload.last_used_at
      expect(first).to be_present

      token.record_use!
      expect(token.reload.last_used_at).to eq(first)

      token.update_column(:last_used_at, 2.hours.ago)
      token.record_use!
      expect(token.reload.last_used_at).to be > first
    end
  end

  it "goes with its user" do
    described_class.generate(user: user, name: "x")
    user.destroy!
    expect(described_class.count).to eq(0)
  end
end
