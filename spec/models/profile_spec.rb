# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Profile do
  let(:household) { Household.create!(name: "Family") }

  def profile(**attributes) = described_class.new(household: household, name: "P#{SecureRandom.hex(2)}", **attributes)

  it "takes a PIN of 4 to 8 digits, and clears it with nil" do
    expect(profile.tap { |p| p.change_pin("123") }.tap(&:valid?).errors[:pin]).to include("must be 4 to 8 digits")
    expect(profile.tap { |p| p.change_pin("12ab") }.tap(&:valid?).errors[:pin]).to be_present
    locked = profile.tap { |p| p.change_pin("1234") }
    locked.save!
    expect(locked).to be_pin
    expect(locked.authenticate_pin("1234")).to be_truthy
    expect(locked.pin_changed_at).to be_present

    locked.change_pin(nil)
    locked.save!
    expect(locked.reload).not_to be_pin
  end

  it "is restricted by a ceiling, curated mode, or a library list — and only then" do
    expect(profile).not_to be_restricted
    expect(profile(max_rating_age: 7)).to be_restricted
    expect(profile(curated: true)).to be_restricted
    expect(profile(library_ids: [ SecureRandom.uuid ])).to be_restricted
    expect(profile(max_rating_age: 9).tap(&:valid?).errors[:max_rating_age]).to be_present
  end

  it "keeps names unique within a household" do
    described_class.create!(household: household, name: "Sam")
    expect(described_class.new(household: household, name: "Sam")).not_to be_valid
    expect(described_class.new(household: Household.create!(name: "Next door"), name: "Sam")).to be_valid
  end

  describe ".open_default_for" do
    it "never opens a PIN profile unasked" do
      locked = described_class.create!(household: household, name: "Private", position: 0).tap { |p| p.change_pin("1234") && p.save! }
      open = described_class.create!(household: household, name: "Everyone", position: 1)

      expect(described_class.default_for(household)).to eq(locked)
      expect(described_class.open_default_for(household)).to eq(open)
    end

    it "makes the household's first profile when it has none" do
      made = described_class.open_default_for(household)
      expect(made).to have_attributes(persisted?: true, name: "Family")
      expect(described_class.default_for(household)).to eq(made)
    end
  end
end
