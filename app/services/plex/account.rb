# typed: strict
# frozen_string_literal: true

module Plex
  # plex.tv, for the parts of Plex that live in the account rather than on
  # the server: who the home users are, and a server token for each, since
  # watch history on a Plex server is per user.
  class Account
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    BASE = "https://plex.tv/api/v2"

    class HomeUser < T::Struct
      const :id, String
      const :uuid, T.nilable(String)
      const :name, String
      const :admin, T::Boolean
      const :protected, T::Boolean
    end

    sig { params(token: String, client_id: String).void }
    def initialize(token:, client_id:)
      @token = token
      @client_id = client_id
    end

    sig { override.returns(String) }
    def service_name = "plex.tv"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # Everyone in the Plex Home, or just the token's owner when the account
    # has no Home.
    sig { returns(T::Array[HomeUser]) }
    def home_users
      raw = json(:get, "/home/users")
      list = raw.is_a?(Hash) ? Array(raw["users"]) : Array(raw)
      users = list.filter_map { |user| home_user(user) }
      users.presence || [ owner ]
    end

    sig { returns(HomeUser) }
    def owner
      user = T.cast(json(:get, "/user"), T::Hash[String, T.untyped])
      T.must(home_user(user.merge("admin" => true)))
    end

    # A token for this home user on the given server: switch to the user,
    # then ask for the server among their resources.
    sig { params(user: HomeUser, machine_identifier: String, pin: T.nilable(String)).returns(String) }
    def server_token_for(user, machine_identifier:, pin: nil)
      switched = T.cast(json(:post, "/home/users/#{CGI.escape(user.uuid || user.id)}/switch#{pin ? "?pin=#{CGI.escape(pin)}" : ''}"),
        T::Hash[String, T.untyped])
      user_token = switched["authToken"].presence || raise(Error, "plex.tv didn't switch to #{user.name}")
      resources = Account.new(token: user_token, client_id: @client_id).resources
      server = resources.find { |resource| resource["clientIdentifier"] == machine_identifier }
      server&.dig("accessToken").presence || raise(Error, "#{user.name} has no access to this Plex server")
    end

    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def resources = Array(json(:get, "/resources?includeHttps=1"))

    private

    sig { params(user: T::Hash[String, T.untyped]).returns(T.nilable(HomeUser)) }
    def home_user(user)
      id = user["id"]&.to_s
      return nil if id.blank?

      HomeUser.new(id: id, uuid: user["uuid"], name: (user["title"] || user["username"] || user["friendlyName"]).to_s.presence || "Plex user #{id}",
        admin: user["admin"] ? true : false, protected: user["protected"] ? true : false)
    end

    sig { params(method: Symbol, path: String).returns(T.untyped) }
    def json(method, path)
      parse_json(http_json(method, "#{BASE}#{path}", headers: headers), blank: true)
    end

    sig { returns(T::Hash[String, String]) }
    def headers = RequestHeaders.for(@token, @client_id)
  end
end
