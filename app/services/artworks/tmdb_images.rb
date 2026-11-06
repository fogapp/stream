# typed: strict
# frozen_string_literal: true

module Artworks
  # TMDB's image CDN. No credentials: the images are public, and a path is
  # only ever one TMDB itself handed us.
  class TmdbImages
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    BASE = "https://image.tmdb.org/t/p"
    MAX_BYTES = T.let(25 * 1024 * 1024, Integer)

    sig { override.returns(String) }
    def service_name = "TMDB images"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    sig { params(path: String, size: String, into: Pathname).void }
    def download(path, size:, into:)
      raise Error, "not a TMDB image path: #{path}" unless path.match?(%r{\A/[\w.-]+\z})

      http_get_file("#{BASE}/#{size}#{path}", into: into, max_bytes: MAX_BYTES)
    end
  end
end
