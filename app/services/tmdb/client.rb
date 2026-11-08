# typed: strict
# frozen_string_literal: true

module Tmdb
  # The Movie Database, through the shared client (PROPOSAL §5.2). Accepts
  # either credential TMDB hands out: a v4 read access token (a JWT, sent as a
  # bearer header) or a v3 API key (sent as a query parameter).
  class Client
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    BASE = "https://api.themoviedb.org/3"

    sig { params(api_key: String, language: String).void }
    def initialize(api_key:, language: "en")
      @api_key = api_key
      @language = language
    end

    sig { override.returns(String) }
    def service_name = "TMDB"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    sig { params(household: Household, language: String).returns(T.nilable(Client)) }
    def self.for(household, language: "en")
      key = TmdbSetting.unscoped.find_by(household_id: household.id)&.api_key
      key.present? ? new(api_key: key, language: language) : nil
    end

    # The cheapest authenticated call, for Settings' Test button.
    sig { returns(T::Hash[String, T.untyped]) }
    def configuration = get("/configuration")

    sig { returns([ T::Boolean, String ]) }
    def test_connection
      answer_test do
        configuration
        "Connected to TMDB."
      end
    end

    sig { params(query: String, year: T.nilable(Integer)).returns(T::Array[T::Hash[String, T.untyped]]) }
    def search_movies(query, year: nil)
      Array(get("/search/movie", query: query, year: year, include_adult: "false")["results"])
    end

    sig { params(query: String, year: T.nilable(Integer)).returns(T::Array[T::Hash[String, T.untyped]]) }
    def search_shows(query, year: nil)
      Array(get("/search/tv", query: query, first_air_date_year: year, include_adult: "false")["results"])
    end

    # imdb_id or tvdb_id → the TMDB records that carry it.
    sig { params(external_id: String, source: String).returns(T::Hash[String, T.untyped]) }
    def find(external_id, source:) = get("/find/#{CGI.escape(external_id)}", external_source: source)

    sig { params(id: Integer).returns(T::Hash[String, T.untyped]) }
    def movie(id)
      get("/movie/#{id}", append_to_response: "credits,release_dates,images,videos,keywords", include_image_language: image_languages,
        include_video_language: image_languages)
    end

    sig { params(id: Integer).returns(T::Hash[String, T.untyped]) }
    def show(id)
      get("/tv/#{id}", append_to_response: "credits,content_ratings,external_ids,images,videos,keywords",
        include_image_language: image_languages, include_video_language: image_languages)
    end

    # Every poster, backdrop and logo TMDB has for a title, for choosing one.
    sig { params(kind: String, id: Integer).returns(T::Hash[String, T.untyped]) }
    def images(kind, id)
      get("/#{kind == 'show' ? 'tv' : 'movie'}/#{id}/images", include_image_language: "#{image_languages},null")
    end

    # A title's videos alone, for titles matched before trailers were kept.
    sig { params(kind: String, id: Integer).returns(T::Array[T::Hash[String, T.untyped]]) }
    def videos(kind, id)
      Array(get("/#{kind == 'show' ? 'tv' : 'movie'}/#{id}/videos", include_video_language: image_languages)["results"])
    end

    sig { params(id: Integer).returns(T::Hash[String, T.untyped]) }
    def collection(id) = get("/collection/#{id}")

    sig { params(show_id: Integer, season_number: Integer).returns(T::Hash[String, T.untyped]) }
    def season(show_id, season_number) = get("/tv/#{show_id}/season/#{season_number}")

    sig { params(request: ::Net::HTTPRequest).void }
    def authorize_request(request)
      request["Authorization"] = "Bearer #{@api_key}" if bearer?
    end

    private

    sig { returns(T::Boolean) }
    def bearer? = @api_key.start_with?("eyJ")

    # Logos in the metadata language first, then language-less ones.
    sig { returns(String) }
    def image_languages = "#{@language.split('-').first},null,en"

    sig { params(path: String, params: T.untyped).returns(T::Hash[String, T.untyped]) }
    def get(path, **params)
      query = params.compact.merge(language: @language)
      query[:api_key] = @api_key unless bearer?
      response = http_get("#{BASE}#{path}?#{URI.encode_www_form(query)}", headers: { "Accept" => "application/json" })
      parse_object(response, strict: true)
    end
  end
end
