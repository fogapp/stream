# typed: strict
# frozen_string_literal: true

module Mlb
  # Settings' Test button for the MLB.tv account (PROPOSAL §7.8): signs in
  # the way yt-dlp's MLB.tv extractor does — Okta's password grant, with the
  # MLB app's client id — so a wrong password shows here, not as a game
  # that won't play. Playing is yt-dlp's (LiveStreams::MlbSource).
  class Account
    extend T::Sig
    include UpstreamHttpClient

    TOKEN_URL = "https://ids.mlb.com/oauth2/aus1m088yK07noBfh356/v1/token"
    CLIENT_ID = "0oa3e1nutA1HLzAKG356"

    sig { params(setting: MlbSetting).void }
    def initialize(setting)
      @setting = setting
    end

    sig { override.returns(String) }
    def service_name = "MLB.tv"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = UpstreamHttpClient::Error

    sig { returns([ T::Boolean, String ]) }
    def test_connection
      response = upstream_request(TOKEN_URL, headers: {}, max_bytes: 64 * 1024) do |uri|
        ::Net::HTTP::Post.new(uri).tap do |request|
          request["Accept"] = "application/json"
          request.set_form_data(grant_type: "password", username: @setting.username, password: @setting.password.to_s,
            scope: "openid offline_access", client_id: CLIENT_ID)
        end
      end
      return [ false, "MLB.tv answered, but didn't sign in" ] if JSON.parse(response.body.to_s)["access_token"].blank?

      [ true, "Signed in to MLB.tv as #{@setting.username}" ]
    rescue JSON::ParserError
      [ false, "MLB.tv's answer wasn't JSON" ]
    rescue UpstreamHttpClient::Error => e
      # Okta answers a wrong password with 400 invalid_grant.
      return [ false, "MLB.tv didn't accept that email and password" ] if [ 400, 401 ].include?(e.status)

      [ false, e.message ]
    end
  end
end
