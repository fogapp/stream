# typed: strict
# frozen_string_literal: true

module Trakt
  # Trakt's API (PROPOSAL §7.4), as the household's registered app. Calls
  # made for a person carry their access token; Trakt::Api keeps that token
  # fresh, since Trakt's expire after a day.
  class Client
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    BASE = "https://api.trakt.tv"

    # What polling for a device code can say (Trakt answers with a status).
    class DeviceStatus < T::Enum
      enums do
        Linked = new
        Pending = new
        SlowDown = new
        Expired = new
        Denied = new
        Invalid = new
      end
    end

    class DevicePoll < T::Struct
      const :status, DeviceStatus
      const :tokens, T::Hash[String, T.untyped], default: {}
    end

    sig { params(setting: TraktSetting).void }
    def initialize(setting)
      @setting = setting
    end

    sig { override.returns(String) }
    def service_name = "Trakt"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # The client id is checked by any call; the secret only when someone links.
    sig { returns([ T::Boolean, String ]) }
    def test_connection
      get("/genres/movies")
      [ true, "Trakt accepted the client ID. The secret is checked when a profile links." ]
    rescue UpstreamHttpClient::AuthError
      [ false, "Trakt didn't accept that client ID." ]
    rescue UpstreamHttpClient::Error => e
      [ false, e.message ]
    end

    # A code for someone to enter at trakt.tv/activate.
    sig { returns(T::Hash[String, T.untyped]) }
    def device_code = post("/oauth/device/code", { client_id: @setting.client_id })

    sig { params(device_code: String).returns(DevicePoll) }
    def device_token(device_code)
      tokens = post("/oauth/device/token", { code: device_code, client_id: @setting.client_id, client_secret: @setting.client_secret })
      DevicePoll.new(status: DeviceStatus::Linked, tokens: tokens)
    rescue UpstreamHttpClient::Error => e
      status = case e.status
      when 400 then DeviceStatus::Pending
      when 429 then DeviceStatus::SlowDown
      when 410 then DeviceStatus::Expired
      when 418 then DeviceStatus::Denied
      when 404, 409 then DeviceStatus::Invalid
      end
      raise if status.nil?

      DevicePoll.new(status: status)
    end

    # New tokens for old. Trakt rotates the refresh token too.
    sig { params(refresh_token: String).returns(T::Hash[String, T.untyped]) }
    def refresh(refresh_token)
      post("/oauth/token", { refresh_token: refresh_token, client_id: @setting.client_id, client_secret: @setting.client_secret,
        redirect_uri: "urn:ietf:wg:oauth:2.0:oob", grant_type: "refresh_token" })
    end

    sig { params(token: String).void }
    def revoke(token)
      post("/oauth/revoke", { token: token, client_id: @setting.client_id, client_secret: @setting.client_secret })
    end

    sig { params(path: String, token: T.nilable(String)).returns(T.untyped) }
    def get(path, token: nil) = request(:get, path, nil, token)

    sig { params(path: String, body: T::Hash[Symbol, T.untyped], token: T.nilable(String)).returns(T.untyped) }
    def post(path, body, token: nil) = request(:post, path, body, token)

    private

    sig do
      params(method: Symbol, path: String, body: T.nilable(T::Hash[Symbol, T.untyped]), token: T.nilable(String)).returns(T.untyped)
    end
    def request(method, path, body, token)
      headers = { "trakt-api-version" => "2", "trakt-api-key" => @setting.client_id }
      headers["Authorization"] = "Bearer #{token}" if token
      parse_json(http_json(method, "#{BASE}#{path}", body: body, headers: headers), blank: true)
    end
  end
end
