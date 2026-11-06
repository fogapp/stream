# typed: strict
# frozen_string_literal: true

module LiveStreams
  # A live stream's card picture as an <img> fetches it (ArtworkUrl's
  # reasoning): signed for the stream and the moment it was taken, so a new
  # picture is a new URL and an old one can be cached.
  module StillUrl
    extend T::Sig

    sig { params(stream: LiveStream).returns(T.nilable(String)) }
    def self.for(stream)
      taken = stream.still_at
      return nil if taken.nil?

      version = taken.to_i
      "/artwork/live/#{stream.id}/#{version}.webp?s=#{signature(stream.id, version)}"
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
      @key ||= T.let(Rails.application.key_generator.generate_key("stream/live-still-urls", 32), T.nilable(String))
    end
    private_class_method :key
  end
end
