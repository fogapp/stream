# typed: strict
# frozen_string_literal: true

module Hook
  # Hook, the household's acquirer, asked for films and television for the
  # person using Stream (PROPOSAL §7.9, hook:ACCESS.md › Another app on the
  # box). Nothing is pasted: connecting Hook's Library offer on Stream's
  # Integrations tab in fog sets HOOK_URL and HOOK_API_TOKEN, a token that
  # may read and ask — search, want a film, add a show, want its seasons,
  # follow it — and manage nothing. Every call names the person in
  # Hook-On-Behalf-Of, so the want is theirs in Hook (or says it was asked
  # for them in Stream, when Hook doesn't know them).
  class Client
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    # Hook's ids are UUIDs; anything else never reaches a path.
    ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    sig { returns(T::Boolean) }
    def self.configured? = ENV["HOOK_URL"].present? && ENV["HOOK_API_TOKEN"].present?

    sig { params(on_behalf_of: T.nilable(String)).void }
    def initialize(on_behalf_of: nil)
      @on_behalf_of = on_behalf_of
    end

    sig { override.returns(String) }
    def service_name = "Hook"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # Hook is a sibling app on the fog network, at the address fog injected.
    sig { override.returns(T::Boolean) }
    def allow_private_addresses? = true # rubocop:disable Stream/NoUnreviewedPrivateEgress

    # Names who Hook takes the asker to be: the person themselves when Hook
    # knows their email, else the admin whose fog connected Stream.
    sig { returns([ T::Boolean, String ]) }
    def test_connection
      answer_test { "Connected to Hook, asking as #{get('/api/v1/me')['name'] || 'its admin'}" }
    end

    # TMDB through Hook: `movie` for films, `episode` for shows. Each hit
    # carries provider + external_id, and movie_id / want_ids or show_id
    # once Hook has it.
    sig { params(media_kind: String, query: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def search(media_kind:, query:)
      list(get_any("/api/v1/search", media_kind: media_kind, q: query))
    end

    sig { params(provider: String, external_id: String).returns(T::Hash[String, T.untyped]) }
    def want_movie(provider:, external_id:)
      send_json(:post, "/api/v1/wants", { media_kind: "movie", provider: provider, external_id: external_id })
    end

    # Adds the show, or answers the one already there: every season with its
    # episodes and each episode's wants, and `following` once followed.
    sig { params(provider: String, external_id: String).returns(T::Hash[String, T.untyped]) }
    def add_show(provider:, external_id:)
      send_json(:post, "/api/v1/shows", { provider: provider, external_id: external_id })
    end

    # Episodes already wanted are left alone: {created, already, show}.
    sig { params(show_id: String, season_number: Integer).returns(T::Hash[String, T.untyped]) }
    def want_season(show_id:, season_number:)
      send_json(:post, "/api/v1/shows/#{checked(show_id)}/want", { scope: "season", season_number: season_number })
    end

    # The follow presets Hook offers a show (new_releases, everything, …),
    # each with the rule to send.
    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def follow_presets
      list(get("/api/v1/monitors/schema", media_kind: "episode", subject_type: "Show")["presets"])
    end

    sig { params(show_id: String, rule: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def follow(show_id:, rule:)
      send_json(:put, "/api/v1/shows/#{checked(show_id)}/follow", { rule: rule })
    end

    private

    sig { returns(String) }
    def base_url = ENV.fetch("HOOK_URL").chomp("/")

    sig { returns(T::Hash[String, String]) }
    def headers
      base = { "Authorization" => "Bearer #{ENV.fetch('HOOK_API_TOKEN')}", "Accept" => "application/json" }
      @on_behalf_of.present? ? base.merge("Hook-On-Behalf-Of" => @on_behalf_of.to_s) : base
    end

    sig { params(id: String).returns(String) }
    def checked(id)
      raise Error, "That isn't one of Hook's shows" unless ID.match?(id)

      id
    end

    sig { params(value: T.untyped).returns(T::Array[T::Hash[String, T.untyped]]) }
    def list(value) = Array(value).grep(Hash)

    sig { params(path: String, query: T::Hash[Symbol, String]).returns(T::Hash[String, T.untyped]) }
    def get(path, query = {}) = parse_object(http_get(with_query("#{base_url}#{path}", query), headers: headers))

    sig { params(path: String, query: T::Hash[Symbol, String]).returns(T.untyped) }
    def get_any(path, query = {})
      parse_json(http_get(with_query("#{base_url}#{path}", query), headers: headers))
    end

    sig { params(method: Symbol, path: String, body: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def send_json(method, path, body)
      parse_object(http_json(method, "#{base_url}#{path}", body: body, headers: headers))
    end
  end
end
