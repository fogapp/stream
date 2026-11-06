# typed: strict
# frozen_string_literal: true

module Plex
  # What plex.tv and a Plex server both ask a client to say of itself.
  module RequestHeaders
    extend T::Sig

    sig { params(token: T.nilable(String), client_id: String).returns(T::Hash[String, String]) }
    def self.for(token, client_id)
      { "Accept" => "application/json", "X-Plex-Token" => token.to_s, "X-Plex-Client-Identifier" => "stream-#{client_id}", "X-Plex-Product" => "Stream" }
    end
  end
end
