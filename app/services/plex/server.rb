# typed: strict
# frozen_string_literal: true

module Plex
  # A Plex Media Server, read-only, over its JSON API (PROPOSAL §7.4).
  class Server
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    PAGE = 500
    # Plex's type numbers for /all listings.
    MOVIE = 1
    SHOW = 2
    EPISODE = 4

    sig { params(url: String, token: String, client_id: String).void }
    def initialize(url:, token:, client_id:)
      @url = url
      @token = token
      @client_id = client_id
    end

    sig { override.returns(String) }
    def service_name = "Plex"

    sig { override.returns(String) }
    def not_json_message = "Plex answered with something that isn't JSON — is that a Plex server?"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # The household's own Plex server, on its LAN, at the address an admin
    # typed into Settings — not a URL content handed us.
    sig { override.returns(T::Boolean) }
    def allow_private_addresses? = true # rubocop:disable Stream/NoUnreviewedPrivateEgress

    # A big library's /all takes a while to render on a small Plex box.
    sig { returns(Integer) }
    def read_timeout = 120

    sig { params(connection: PlexConnection, token: T.nilable(String)).returns(Server) }
    def self.for(connection, token: nil)
      new(url: connection.server_url, token: token || connection.token.to_s, client_id: connection.household_id)
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def identity = container("/identity")

    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def sections = Array(container("/library/sections")["Directory"])

    # Every item of a type in a section, a page at a time, with the external
    # ids Plex matched it to (includeGuids).
    sig { params(section_key: String, type: Integer, block: T.proc.params(item: T::Hash[String, T.untyped]).void).void }
    def each_item(section_key, type:, &block)
      each_page(section_key, type: type) { |items| items.each(&block) }
    end

    # The same, a page of items at a time.
    sig { params(section_key: String, type: Integer, block: T.proc.params(items: T::Array[T::Hash[String, T.untyped]]).void).void }
    def each_page(section_key, type:, &block)
      start = 0
      loop do
        page = container("/library/sections/#{CGI.escape(section_key)}/all",
          query: { type: type, includeGuids: 1, "X-Plex-Container-Start" => start, "X-Plex-Container-Size" => PAGE })
        items = Array(page["Metadata"])
        block.call(items)
        start += items.size
        total = page["totalSize"].to_i
        break if items.size < PAGE || (total.positive? && start >= total)
      end
    end

    # A section's collections; smart ones say so ("smart": "1").
    sig { params(section_key: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def collections(section_key) = Array(container("/library/sections/#{CGI.escape(section_key)}/collections")["Metadata"])

    # A section's genres, id to name, for reading a smart collection's filter.
    sig { params(section_key: String).returns(T::Hash[String, String]) }
    def genres(section_key)
      Array(container("/library/sections/#{CGI.escape(section_key)}/genre")["Directory"]).to_h { |genre| [ genre["key"].to_s, genre["title"].to_s ] }
    end

    sig { params(rating_key: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def collection_items(rating_key) = Array(container("/library/collections/#{CGI.escape(rating_key)}/children")["Metadata"])

    # This user's video playlists; smart ones say so.
    sig { returns(T::Array[T::Hash[String, T.untyped]]) }
    def playlists = Array(container("/playlists", query: { playlistType: "video" })["Metadata"])

    sig { params(rating_key: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def playlist_items(rating_key) = Array(container("/playlists/#{CGI.escape(rating_key)}/items")["Metadata"])

    # A picture Plex serves (a custom poster, a collection's art): a path
    # on this server, never a URL from elsewhere.
    sig { params(path: String, into: Pathname).void }
    def download(path, into:)
      raise Error, "not a Plex image path: #{path}" unless path.match?(%r{\A/library/[\w/.-]+\z})

      http_get_file("#{@url}#{path}", into: into, headers: headers.except("Accept"))
    end

    private

    sig { params(path: String, query: T::Hash[T.untyped, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def container(path, query: {})
      container = parse_object(http_get(with_query("#{@url}#{path}", query), headers: headers))["MediaContainer"]
      raise Error, "Plex answered without a MediaContainer" unless container.is_a?(Hash)

      container
    end

    sig { returns(T::Hash[String, String]) }
    def headers = RequestHeaders.for(@token, @client_id)
  end
end
