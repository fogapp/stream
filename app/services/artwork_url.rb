# typed: strict
# frozen_string_literal: true

# Signed artwork URLs (PROPOSAL §3.3's reasoning, applied to images): an
# <img> can't send the bearer token, so the URL carries proof that Stream
# issued it. The signature covers the artwork and its version, so a URL is
# good forever for exactly that render and the browser can cache it
# immutably; a re-render is a new URL.
module ArtworkUrl
  extend T::Sig

  sig { params(artwork: Artwork, width: Integer).returns(String) }
  def self.for(artwork, width)
    "/artwork/#{artwork.id}/#{artwork.version}/#{width}.webp?s=#{signature(artwork.id, artwork.version)}"
  end

  sig { params(id: String, version: Integer, signature: String).returns(T::Boolean) }
  def self.valid?(id, version, signature)
    ActiveSupport::SecurityUtils.secure_compare(signature(id, version), signature.to_s)
  end

  sig { params(id: String, version: Integer).returns(String) }
  def self.signature(id, version)
    OpenSSL::HMAC.hexdigest("SHA256", key, "#{id}/#{version}").first(24)
  end
  private_class_method :signature

  sig { returns(String) }
  def self.key
    @key ||= T.let(Rails.application.key_generator.generate_key("stream/artwork-urls", 32), T.nilable(String))
  end
  private_class_method :key
end
