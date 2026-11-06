# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Subtitles::Languages do
  it "knows a language by its two-letter code and both three-letter ones" do
    expect(described_class.codes("fr")).to contain_exactly("fr", "fre", "fra")
    expect(described_class.codes("de")).to contain_exactly("de", "ger", "deu")
    expect(described_class.codes("pt")).to contain_exactly("pt", "por")
    expect(described_class.codes("ja")).to contain_exactly("ja", "jpn")
  end

  it "takes a regional code as its language" do
    expect(described_class.codes("pt-BR")).to contain_exactly("pt", "por")
    expect(described_class.codes("zh-CN")).to contain_exactly("zh", "chi", "zho")
  end

  it "keeps a code it doesn't know" do
    expect(described_class.codes("xx")).to eq([ "xx" ])
  end

  it "matches a track tagged either way, or with a region" do
    expect(described_class.same?("fr", "fra")).to be(true)
    expect(described_class.same?("fr", "FRE")).to be(true)
    expect(described_class.same?("pt-BR", "pt-br")).to be(true)
    expect(described_class.same?("en", "fr")).to be(false)
    expect(described_class.same?("en", nil)).to be(false)
  end
end
