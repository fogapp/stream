# typed: strict
# frozen_string_literal: true

module Middleware
  # HTML goes out as a body, never by X-Sendfile. ActionDispatch::Static
  # answers `/` with public/index.html, and in production Rack::Sendfile
  # hands that to Thruster as an empty body plus an X-Sendfile header. The
  # glass agent sits above both and rewrites HTML to add its script tag: it
  # saw the empty body, wrote the bare tag with its own Content-Length, and
  # Thruster's file no longer matched it — every load of `/` was a 502. The
  # shell is a kilobyte; reading it here keeps what's above honest.
  class InlineHtml
    extend T::Sig

    SENDFILE = "x-sendfile"

    sig { params(app: T.untyped).void }
    def initialize(app)
      @app = app
    end

    sig { params(env: T::Hash[String, T.untyped]).returns(T.untyped) }
    def call(env)
      status, headers, body = @app.call(env)
      path = headers[SENDFILE]
      return [ status, headers, body ] unless path && headers["content-type"].to_s.start_with?("text/html")

      html = File.binread(path.to_s)
      body.close if body.respond_to?(:close)
      headers.delete(SENDFILE)
      headers["content-length"] = html.bytesize.to_s
      [ status, headers, [ html ] ]
    end
  end
end
