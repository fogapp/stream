# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Library do
  let(:household) { Household.create!(name: "Family") }

  def library(roots:, **attributes) = described_class.new(household: household, name: "L#{SecureRandom.hex(2)}", kind: "movies", roots: roots,
    **attributes)

  it "needs a folder Stream can see, and not too many" do
    expect(library(roots: []).tap(&:valid?).errors[:roots]).to include("need at least one folder")
    expect(library(roots: [ "/definitely/not/mounted" ]).tap(&:valid?).errors[:base].join).to include("/definitely/not/mounted")
    many = Array.new(Library::MAX_ROOTS + 1) { build_root }
    expect(library(roots: many).tap(&:valid?).errors[:roots]).to include("can have at most #{Library::MAX_ROOTS} folders")
    expect(library(roots: [ build_root ])).to be_valid
  end

  it "refuses folders that contain one another, which would list a file twice" do
    outer = build_root
    inner = File.join(outer, "Films").tap { |path| FileUtils.mkdir_p(path) }

    expect(library(roots: [ outer, inner ]).tap(&:valid?).errors[:roots].join).to include("can't contain one another")
  end

  it "names a metadata language the way TMDB takes it" do
    expect(library(roots: [ build_root ], metadata_language: "en-GB")).to be_valid
    expect(library(roots: [ build_root ], metadata_language: "english").tap(&:valid?).errors[:metadata_language]).to be_present
  end
end
