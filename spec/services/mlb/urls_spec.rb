# typed: false
# frozen_string_literal: true

require "rails_helper"

# A pasted MLB.tv link is rebuilt from the game's number before yt-dlp sees
# it (PROPOSAL §7.8).
RSpec.describe Mlb::Urls do
  it "keeps only the game's number from a game's link" do
    expect(described_class.game_url("https://www.mlb.com/tv/g745652/vafbc56d6-7ad9-476d-98bb-04a247761609#game=745652"))
      .to eq("https://www.mlb.com/tv/g745652")
    expect(described_class.game_url(" mlb.com/tv/g745652?affiliateId=x ")).to eq("https://www.mlb.com/tv/g745652")
  end

  it "refuses anything else" do
    [ "https://example.com/tv/g745652", "https://www.mlb.com/tv/", "https://www.mlb.com/tv/g74565", "https://www.mlb.com/tv/g7456521",
      "https://www.mlb.com/news/g745652", "https://www.mlb.com/gameday/745652", "https://www.mlb.com.evil.test/tv/g745652" ].each do |text|
      expect { described_class.game_url(text) }.to raise_error(Mlb::Urls::Invalid), text
    end
  end
end
