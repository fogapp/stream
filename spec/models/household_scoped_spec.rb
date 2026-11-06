# typed: false
# frozen_string_literal: true

require "rails_helper"

# Household tenancy (app/models/concerns/household_scoped.rb): what every
# household-owned query leans on.
RSpec.describe HouseholdScoped do
  let(:ours) { Household.create!(name: "Ours") }
  let(:theirs) { Household.create!(name: "Theirs") }

  it "sees only the current household's rows, and everything when there is none (jobs, console)" do
    Collection.create!(household: ours, title: "Mine", kind: "manual")
    Collection.create!(household: theirs, title: "Theirs", kind: "manual")

    Current.set(household: ours) { expect(Collection.pluck(:title)).to eq([ "Mine" ]) }
    expect(Collection.pluck(:title)).to contain_exactly("Mine", "Theirs")
  end

  it "files a new row under the current household, never one it's handed from outside" do
    made = Current.set(household: ours) { Collection.create!(title: "Made here", kind: "manual") }
    expect(made.household).to eq(ours)

    expect(Collection.new(title: "Nowhere", kind: "manual")).not_to be_valid
  end

  it "finds nothing of another household's by id" do
    other = Collection.create!(household: theirs, title: "Theirs", kind: "manual")

    Current.set(household: ours) do
      expect(Collection.find_by(id: other.id)).to be_nil
      expect { Collection.find(other.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
