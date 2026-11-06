# typed: strict
# frozen_string_literal: true

module Playback
  # The signing every token in a media path shares (/media/s, /media/d,
  # /media/n): "<fields>.<signature>", an HMAC of the fields under
  # STREAM_TOKEN_KEY, with a purpose prefix so one kind can't pass as
  # another. Rotating the key revokes them all without signing anyone out.
  module SignedToken
    extend T::Sig

    sig { params(purpose: String, fields: String).returns(String) }
    def self.issue(purpose, *fields)
      payload = fields.join(".")
      "#{payload}.#{sign(purpose, payload)}"
    end

    # The fields a genuine token carries, or nil for anything forged or
    # malformed.
    sig { params(purpose: String, token: String, count: Integer).returns(T.nilable(T::Array[String])) }
    def self.fields(purpose, token, count: 1)
      *fields, signature = token.to_s.split(".", count + 1)
      return nil if fields.size != count || signature.nil?
      return nil unless ActiveSupport::SecurityUtils.secure_compare(sign(purpose, fields.join(".")), signature)

      fields
    end

    sig { params(purpose: String, payload: String).returns(String) }
    def self.sign(purpose, payload) = OpenSSL::HMAC.hexdigest("SHA256", key, "#{purpose}#{payload}").first(32)
    private_class_method :sign

    sig { returns(String) }
    def self.key
      ENV["STREAM_TOKEN_KEY"].presence ||
        Rails.application.key_generator.generate_key("stream/stream-tokens", 32).unpack1("H*")
    end
    private_class_method :key
  end
end
