# typed: strict
# frozen_string_literal: true

module Mlb
  # A pasted MLB.tv link, rebuilt as the game's canonical link (PROPOSAL
  # §7.8). Only a link this module built from a validated game number is
  # ever handed to yt-dlp, as with Youtube::Urls.
  module Urls
    extend T::Sig

    class Invalid < StandardError; end

    HOSTS = T.let(%w[mlb.com www.mlb.com].to_set.freeze, T::Set[String])
    # What yt-dlp's MLB.tv extractor takes: g and six digits.
    GAME = /\Ag(\d{6})\z/

    sig { params(text: String).returns(String) }
    def self.game_url(text) = "https://www.mlb.com/tv/g#{game_id(text)}"

    # A game from MLB's schedule, by its number.
    sig { params(game_pk: Integer).returns(String) }
    def self.for_game(game_pk) = game_url("https://www.mlb.com/tv/g#{game_pk}")

    # The game's number (MLB's gamePk), from a link like
    # https://www.mlb.com/tv/g745652/vafbc56d6-…#game=745652.
    sig { params(text: String).returns(String) }
    def self.game_id(text)
      raw = text.strip
      raw = "https://#{raw}" unless raw.match?(%r{\Ahttps?://}i)
      uri = URI.parse(raw)
      raise Invalid, "That isn't an MLB.tv link" unless HOSTS.include?(uri.host.to_s.downcase)

      tv, game = uri.path.to_s.split("/").reject(&:empty?)
      id = game.to_s[GAME, 1]
      raise Invalid, "Paste a game's link from MLB.tv: mlb.com/tv/g…" if tv != "tv" || id.nil?

      id
    rescue URI::InvalidURIError
      raise Invalid, "That isn't a link"
    end
  end
end
