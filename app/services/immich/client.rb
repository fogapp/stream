# typed: strict
# frozen_string_literal: true

module Immich
  # Immich's API, read-only (PROPOSAL §5.4): people, video assets with their
  # EXIF and faces, albums, and face thumbnails.
  class Client
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    PAGE = 250

    sig { params(setting: ImmichSetting).void }
    def initialize(setting)
      @setting = setting
    end

    sig { override.returns(String) }
    def service_name = "Immich"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # Immich runs beside Stream on the LAN, at the address an admin typed.
    sig { override.returns(T::Boolean) }
    def allow_private_addresses? = true # rubocop:disable Stream/NoUnreviewedPrivateEgress

    sig { returns([ T::Boolean, String ]) }
    def test_connection = answer_test { "Connected to Immich #{get('/api/server/about')['version']}".strip }

    # Named people (unnamed faces can't be filtered by).
    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def people
      Array(get("/api/people", withHidden: "false")["people"]).select { |person| person["name"].to_s.strip.present? }
    end

    # Every video asset, a page at a time, with its EXIF and faces.
    sig { params(block: T.proc.params(asset: T::Hash[String, T.untyped]).void).void }
    def each_video(&block)
      page = T.let(1, T.nilable(T.any(Integer, String)))
      while page
        data = post("/api/search/metadata", { type: "VIDEO", page: page, size: PAGE, withExif: true, withPeople: true })
        assets = data["assets"].is_a?(Hash) ? data["assets"] : {}
        Array(assets["items"]).each do |asset|
          # A Live Photo's motion part is hidden in Immich; it isn't a video.
          next if asset["visibility"] == "hidden" || asset["isVisible"] == false

          block.call(asset)
        end
        page = assets["nextPage"].presence
      end
    end

    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def albums
      data = get_any("/api/albums")
      data.is_a?(Array) ? data : []
    end

    sig { params(id: String).returns(T::Array[String]) }
    def album_asset_ids(id)
      Array(get("/api/albums/#{CGI.escape(id)}")["assets"]).filter_map { |asset| asset["id"].presence }
    end

    sig { params(person_id: String, into: Pathname).void }
    def person_thumbnail(person_id, into:)
      http_get_file("#{@setting.url}/api/people/#{CGI.escape(person_id)}/thumbnail", into: into, headers: headers)
    end

    private

    sig { returns(T::Hash[String, String]) }
    def headers = { "x-api-key" => @setting.api_key.to_s, "Accept" => "application/json" }

    sig { params(path: String, query: T::Hash[Symbol, String]).returns(T::Hash[String, T.untyped]) }
    def get(path, query = {}) = parse_object(http_get(with_query("#{@setting.url}#{path}", query), headers: headers))

    sig { params(path: String, query: T::Hash[Symbol, String]).returns(T.untyped) }
    def get_any(path, query = {})
      parse_json(http_get(with_query("#{@setting.url}#{path}", query), headers: headers))
    end

    sig { params(path: String, body: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def post(path, body)
      parse_object(http_post_json("#{@setting.url}#{path}", body: body, headers: headers))
    end
  end
end
