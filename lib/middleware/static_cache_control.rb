# typed: strict
# frozen_string_literal: true

module Middleware
  # production.rb gives everything ActionDispatch::Static serves a one-year
  # header, which is only true of the content-hashed files in /assets. The
  # file server also answers `/` with public/index.html before the SPA route
  # sees it, so the shell was cached for a year too: after a deploy a browser
  # reused its old index.html, asked for bundles the new image no longer has,
  # and showed a blank page until a hard refresh. This rewrites the header on
  # the way out — the HTML revalidates every load, other unhashed files
  # (sw.js, icons, the manifest) last an hour.
  class StaticCacheControl
    extend T::Sig

    DIGEST_STAMPED_PREFIX = "/assets/"
    HTML_EXTENSIONS = T.let([ "", ".html" ].freeze, T::Array[String])
    HTML_CACHE_CONTROL = "no-cache"
    UNSTAMPED_CACHE_CONTROL = T.let("public, max-age=#{1.hour.to_i}", String)

    sig { params(app: T.untyped, static_cache_control: T.nilable(String)).void }
    def initialize(app, static_cache_control: nil)
      @app = app
      @static_cache_control = T.let(
        static_cache_control || Rails.application.config.public_file_server.headers.to_h["cache-control"],
        T.nilable(String)
      )
    end

    sig { params(env: T::Hash[String, T.untyped]).returns(T.untyped) }
    def call(env)
      status, headers, body = @app.call(env)
      rewrite(env["PATH_INFO"].to_s, headers)
      [ status, headers, body ]
    end

    private

    sig { params(path: String, headers: T.untyped).void }
    def rewrite(path, headers)
      return if @static_cache_control.blank?
      # Only responses the file server produced carry its header verbatim.
      return unless headers["cache-control"] == @static_cache_control
      return if path.start_with?(DIGEST_STAMPED_PREFIX)

      # Keyed off the path, not Content-Type: a 304 has no Content-Type.
      headers["cache-control"] =
        HTML_EXTENSIONS.include?(File.extname(path)) ? HTML_CACHE_CONTROL : UNSTAMPED_CACHE_CONTROL
    end
  end
end
