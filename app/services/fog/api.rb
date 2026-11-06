# typed: strict
# frozen_string_literal: true

module Fog
  # The app-facing fog surface Stream reads (fog:docs/files-contract.md):
  # where its own folders come from (GET /app/v1/files/mounts) and the apps
  # it uses with the path translations to them (GET /app/v1/connections).
  # Fog injects FOG_API_URL and FOG_API_TOKEN; without them — Stream outside
  # fog — every answer is nil and nothing changes.
  class Api
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    class Mount < T::Struct
      const :mount, String
      const :host_path, String
      const :read_only, T::Boolean
    end

    sig { returns(T::Boolean) }
    def self.available? = ENV["FOG_API_URL"].present? && ENV["FOG_API_TOKEN"].present?

    sig { override.returns(String) }
    def service_name = "Fog"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # Fog runs on this machine and hands the app its own address.
    sig { override.returns(T::Boolean) }
    def allow_private_addresses? = true # rubocop:disable Stream/NoUnreviewedPrivateEgress

    sig { override.returns(Integer) }
    def read_timeout = 5

    # Stream's Files-backed folders; nil when fog can't be asked.
    sig { returns(T.nilable(T::Array[Mount])) }
    def mounts
      body = get_json("/app/v1/files/mounts")
      return nil unless body.is_a?(Hash)

      Array(body["mounts"]).grep(Hash).map do |m|
        Mount.new(mount: m["mount"].to_s, host_path: m["hostPath"].to_s, read_only: m["readOnly"] == true)
      end
    end

    # Every { "remote", "local" } path row fog hands over, across the apps
    # Stream uses; nil when fog can't be asked.
    sig { returns(T.nilable(T::Array[T::Hash[String, String]])) }
    def path_rows
      body = get_json("/app/v1/connections")
      return nil unless body.is_a?(Hash)

      Array(body["connections"]).grep(Hash).flat_map do |c|
        Array(c["paths"]).grep(Hash).map { |r| { "remote" => r["remote"].to_s, "local" => r["local"].to_s } }
      end
    end

    private

    sig { params(path: String).returns(T.untyped) }
    def get_json(path)
      return nil unless self.class.available?

      response = http_get("#{ENV.fetch('FOG_API_URL').chomp('/')}#{path}",
        headers: { "Authorization" => "Bearer #{ENV.fetch('FOG_API_TOKEN')}", "Accept" => "application/json" })
      JSON.parse(response.body.to_s)
    rescue UpstreamHttpClient::Error, JSON::ParserError
      nil
    end
  end
end
