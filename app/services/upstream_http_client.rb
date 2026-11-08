# typed: strict
# frozen_string_literal: true

# Rails does not require net/http for you, and inside this module a bare
# `Net::` would resolve against UpstreamHttpClient first — hence the require
# plus the fully-qualified ::Net:: references below.
require "net/http"
require "zlib"

# The one sanctioned way to make outbound HTTP requests (cop-enforced: raw
# Net::HTTP is banned elsewhere in app/). Provides explicit timeouts, a shared
# circuit breaker, the private-address guard, capped streaming reads, and
# typed errors.
#
# Includers implement service_name and error_class. Every verb below builds
# its request and hands it to one pipeline (#upstream_request), so a fix to the guard,
# the breaker, a timeout or a cap is made once and applies to all of them.
module UpstreamHttpClient
  extend T::Sig
  extend T::Helpers

  abstract!
  requires_ancestor { Kernel }

  class Error < StandardError
    extend T::Sig

    sig { returns(T.nilable(Integer)) }
    attr_reader :status

    # What the upstream itself said, when it said anything useful — already
    # folded into the message, and kept separately so a caller can rephrase
    # around it without re-parsing a sentence.
    sig { returns(T.nilable(String)) }
    attr_reader :detail

    sig { params(message: String, status: T.nilable(Integer), detail: T.nilable(String), connection: T::Boolean).void }
    def initialize(message, status: nil, detail: nil, connection: false)
      @status = status
      @detail = detail
      @connection = connection
      super(message)
    end

    # True when the host could not be reached at all (NETWORK_ERRORS, or the
    # circuit breaker holding the door): the kind of failure that heals
    # itself when the network does. Callers use it to be patient — record
    # and retry — where an application-level error deserves louder handling.
    sig { returns(T::Boolean) }
    def connection? = @connection

    # This error class's rate-limited kind: still one of its own (a
    # `rescue Nba::Schedule::Error` catches it), and tagged
    # UpstreamHttpClient::RateLimitError for whoever treats a rate limit
    # as the provider condition it is (`retry_on`, a budget).
    sig { returns(T.class_of(Error)) }
    def self.rate_limited = tagged(:RateLimited, RateLimitError)

    # Likewise, its rejected-credentials kind, tagged AuthError.
    sig { returns(T.class_of(Error)) }
    def self.unauthorized = tagged(:Unauthorized, AuthError)

    TAGGED_LOCK = T.let(Mutex.new, Thread::Mutex)
    TAGGED = T.let({}, T::Hash[[ T.class_of(Error), Symbol ], T.class_of(Error)])

    # Defined once per error class, on first use, and named as a constant
    # under it (Nba::Schedule::Error::RateLimited), so logs and Activity
    # say whose it was.
    sig { params(name: Symbol, tag: T::Module[T.anything]).returns(T.class_of(Error)) }
    def self.tagged(name, tag)
      TAGGED_LOCK.synchronize do
        TAGGED[[ self, name ]] ||= begin
          klass = Class.new(self)
          klass.include(tag)
          const_set(name, klass)
          klass
        end
      end
    end
    private_class_method :tagged
  end

  # Tags, not classes, so a rate limit or a refusal can be an instance of
  # the including client's own error_class (which its callers rescue) and
  # still be told apart from every other failure: `rescue
  # UpstreamHttpClient::RateLimitError` and `retry_on` match a module as
  # they do a class. Raise them through `error_class.rate_limited` /
  # `error_class.unauthorized`, never directly.
  #
  # RateLimitError is distinct so callers can zero a provider's budget
  # without marking every source under it as failing (manor's scheduler
  # lesson: a rate limit is a provider condition, not a per-source one).
  module RateLimitError; end
  module AuthError; end

  # read_timeout bounds the wait for each individual read; nothing bounded
  # their sum, so a connection trickling one byte every 25 seconds never
  # raised anything and held its worker thread for days inside the byte cap —
  # invisible to the circuit breaker, which only sees exceptions. Raised when
  # a body read outlives its wall-clock budget, and listed in NETWORK_ERRORS
  # because a host that won't finish is as unreachable as one that won't
  # answer.
  class DeadlineExceeded < StandardError; end

  # Everything that means "the network/host is the problem" rather than "the
  # app said no" — these trip the breaker; HTTP status errors do not.
  NETWORK_ERRORS = T.let([
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
    Errno::ENETUNREACH, SocketError, ::Net::OpenTimeout, ::Net::ReadTimeout,
    OpenSSL::SSL::SSLError, IOError, EOFError, DeadlineExceeded
  ].freeze, T::Array[T.class_of(StandardError)])

  # URI errors are the app's problem (a garbage Location header, a malformed
  # configured URL), never the host's — three bad redirects inside five
  # minutes must not blacklist an origin that is answering fine, so these
  # raise typed errors without tripping the breaker.
  URI_ERRORS = T.let([ URI::InvalidURIError, URI::BadURIError ].freeze,
    T::Array[T.class_of(StandardError)])

  MAX_REDIRECTS = T.let(3, Integer)
  MAX_BODY_BYTES = T.let(10 * 1024 * 1024, Integer)
  # Chunk size for reading a body, and for inflating one. Small enough that
  # the cap below is enforced before the memory is committed rather than after.
  BODY_CHUNK_BYTES = T.let(64 * 1024, Integer)
  # A file streamed to disk — artwork, a subtitle, a yt-dlp build — is capped
  # on its own terms.
  MAX_FILE_BYTES = T.let(1024 * 1024 * 1024, Integer) # 1 GiB
  FILE_MAX_REDIRECTS = T.let(5, Integer)

  JSON_VERBS = T.let({
    get: ::Net::HTTP::Get, post: ::Net::HTTP::Post, put: ::Net::HTTP::Put,
    patch: ::Net::HTTP::Patch, delete: ::Net::HTTP::Delete
  }.freeze, T::Hash[Symbol, T.class_of(::Net::HTTPRequest)])

  # An honest, stable User-Agent is an operational requirement in the
  # Cloudflare-default-bot-blocking era, not a courtesy.
  sig { returns(String) }
  def user_agent
    "Stream/#{StreamVersion.short_sha} (+self-hosted media server)"
  end

  sig { returns(Integer) }
  def open_timeout = 5

  sig { returns(Integer) }
  def read_timeout = 30

  # Wall-clock budget for reading one response body, counted from the first
  # chunk — the wait for that first byte is read_timeout's job, which is why
  # this doesn't start at the request (an upload can legitimately be
  # processed for minutes before the server answers; its answer must still
  # arrive promptly). Generous on purpose: 10 MB inside 150s is under 70 KB/s,
  # slower than any working origin, while a drip-feeding one gets cut off the
  # same day it starts instead of never.
  sig { returns(Integer) }
  def body_deadline = read_timeout * 5

  # Same idea for file downloads, scaled to their size: a 1 GiB enclosure at
  # 30 minutes still only requires ~600 KB/s.
  sig { returns(Integer) }
  def file_deadline = 30 * 60

  sig { abstract.returns(String) }
  def service_name; end

  sig { abstract.returns(T.class_of(Error)) }
  def error_class; end

  # A response's JSON; the upstream's own error, saying so, when it isn't.
  # `blank`: an empty body is an answer, and nil.
  sig { params(response: T.untyped, blank: T::Boolean).returns(T.untyped) }
  def parse_json(response, blank: false)
    text = response.body.to_s
    return nil if blank && text.empty?

    JSON.parse(text)
  rescue JSON::ParserError
    raise error_class, not_json_message
  end

  sig { overridable.returns(String) }
  def not_json_message = "#{service_name} answered with something that isn't JSON"

  # A URL with a query, if there is one.
  sig { params(url: String, query: T::Hash[T.untyped, T.untyped]).returns(String) }
  def with_query(url, query) = query.empty? ? url : "#{url}?#{URI.encode_www_form(query)}"

  # A JSON object; any other JSON is {} — or, `strict`, an error.
  sig { params(response: T.untyped, strict: T::Boolean).returns(T::Hash[String, T.untyped]) }
  def parse_object(response, strict: false)
    data = parse_json(response)
    return data if data.is_a?(Hash)
    raise error_class, "#{service_name} answered with something that isn't an object" if strict

    {}
  end

  # A Test button's answer: what the block says on success, or what went
  # wrong (the stored result, and the line under the button).
  sig { params(block: T.proc.returns(String)).returns([ T::Boolean, String ]) }
  def answer_test(&block)
    [ true, block.call ]
  rescue Error => e
    [ false, e.message ]
  end

  sig { params(url: String).returns(String) }
  def circuit_key(url)
    host = URI.parse(url).host
    "#{service_name.downcase}:#{host}"
  rescue URI::InvalidURIError
    service_name.downcase
  end

  # Whether this client is allowed to reach the machine's own network.
  #
  # False for everything that fetches from somewhere someone else chose — a
  # catalog provider, a Goodreads shelf, wherever any of those redirect —
  # because those are the paths an attacker can aim. True only for clients
  # that talk to infrastructure the household configured and expects to be
  # private: the sibling apps on the fog
  # network. Each opt-in carries its reason next to the override.
  sig { returns(T::Boolean) }
  def allow_private_addresses? = false

  # The chokepoint. Every outbound request runs through here, including each
  # hop of a redirect chain — a guard that only checked the URL the caller
  # passed would be no guard at all, since following redirects is exactly how
  # a hostile host reaches an address it was never given.
  #
  # Returns the vetted address to pin the connection to (Net::HTTP#ipaddr=),
  # or nil for clients that opted into private addresses. Pinning is what
  # makes the guard real: connecting by name would resolve again, and a name
  # that answers differently the second time walks right past the check.
  # Host/SNI/certificate verification still use the original hostname.
  sig { params(url: String).returns(T.nilable(String)) }
  def guard_address!(url)
    return nil if allow_private_addresses?

    UpstreamAddressGuard.check!(url, service_name: service_name)
  rescue UpstreamAddressGuard::Blocked => e
    raise error_class.new(e.message)
  end

  # GET, following redirects (each hop re-guarded).
  sig do
    params(url: String, headers: T::Hash[String, String], redirects_left: Integer, max_bytes: Integer)
      .returns(UpstreamHttpClient::Response)
  end
  def http_get(url, headers: {}, redirects_left: MAX_REDIRECTS, max_bytes: MAX_BODY_BYTES)
    upstream_request(url, headers: headers, max_bytes: max_bytes, redirects_left: redirects_left) do |uri|
      ::Net::HTTP::Get.new(uri).tap { |request| request["Accept-Encoding"] = "gzip" }
    end
  end

  sig do
    params(url: String, body: T::Hash[T.untyped, T.untyped], headers: T::Hash[String, String],
      max_bytes: Integer, read_timeout: T.nilable(Integer))
      .returns(UpstreamHttpClient::Response)
  end
  def http_post_json(url, body:, headers: {}, max_bytes: MAX_BODY_BYTES, read_timeout: nil)
    http_json(:post, url, body: body, headers: headers, max_bytes: max_bytes, read_timeout: read_timeout)
  end

  # JSON request with any verb — PATCH and DELETE for APIs that update records
  # in place (Sonarr/Radarr, Immich). Redirects are not followed: a JSON write
  # that bounces somewhere else is an error to report, not a hop to take.
  sig do
    params(method: Symbol, url: String, body: T.nilable(T::Hash[T.untyped, T.untyped]),
      headers: T::Hash[String, String], max_bytes: Integer, read_timeout: T.nilable(Integer))
      .returns(UpstreamHttpClient::Response)
  end
  def http_json(method, url, body: nil, headers: {}, max_bytes: MAX_BODY_BYTES, read_timeout: nil)
    verb = JSON_VERBS.fetch(method)
    upstream_request(url, headers: headers, max_bytes: max_bytes, read_timeout: read_timeout) do |uri|
      request = verb.new(uri)
      request["Accept"] = "application/json"
      unless body.nil?
        request["Content-Type"] = "application/json"
        request.body = body.to_json
      end
      request
    end
  end

  # Multipart upload, for the APIs that take a file. The file is streamed from disk by Net::HTTP rather
  # than read into a string first. `read_timeout` is separate because an
  # upload can legitimately be processed for minutes before the answer.
  sig do
    params(url: String, file: Pathname, filename: String, content_type: String,
      fields: T::Hash[String, String], headers: T::Hash[String, String],
      read_timeout: T.nilable(Integer), part_name: String).returns(UpstreamHttpClient::Response)
  end
  def http_post_multipart(url, file:, filename:, content_type:, fields: {}, headers: {},
    read_timeout: nil, part_name: "file")
    file.open("rb") do |handle|
      upstream_request(url, headers: headers, max_bytes: MAX_BODY_BYTES, read_timeout: read_timeout) do |uri|
        request = ::Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        # Mixed shapes on purpose: plain fields are pairs, the file part carries
        # a third element of metadata, which is the form Net::HTTP#set_form expects.
        # The part name is the API's to choose — "file" for most, "nzbfile" for
        # SABnzbd's addfile.
        parts = T.let(fields.map { |name, value| [ name, value ] }, T::Array[T.untyped])
        parts << [ part_name, handle, { filename: filename, content_type: content_type } ]
        request.set_form(parts, "multipart/form-data")
        request
      end
    end
  end

  # Stream for auth headers; applied after caller-supplied headers so a builder
  # can still override.
  sig { params(request: ::Net::HTTPRequest).void }
  def authorize_request(request); end

  # Streams a GET straight to disk — for a file that would never fit the
  # in-memory path (a large download). Same guard, breaker and typed
  # errors as upstream_request; per-chunk read_timeout means a slow-but-
  # flowing download survives while a stalled socket still times out. A
  # partial file never survives failure.
  #
  # No Accept-Encoding: gzip — the bytes must land exactly as served, because
  # the far side declares a digest over them.
  sig do
    params(url: String, into: Pathname, max_bytes: Integer, headers: T::Hash[String, String],
      redirects_left: Integer, read_timeout: T.nilable(Integer)).returns(UpstreamHttpClient::FileDownload)
  end
  def http_get_file(url, into:, max_bytes: MAX_FILE_BYTES, headers: {},
    redirects_left: FILE_MAX_REDIRECTS, read_timeout: nil)
    uri, request, pinned, key = prepare_request(url, headers: headers) { |target| ::Net::HTTP::Get.new(target) }

    result = T.let(nil, T.nilable(FileDownload))
    redirect_to = T.let(nil, T.nilable(String))
    ::Net::HTTP.start(
      T.must(uri.host), uri.port,
      use_ssl: uri.scheme == "https", open_timeout: open_timeout,
      read_timeout: read_timeout || self.read_timeout, ipaddr: pinned
    ) do |http|
      http.request(request) do |response|
        case response
        when ::Net::HTTPSuccess
          result = stream_to_file(response, into, max_bytes: max_bytes, url: url)
        when ::Net::HTTPRedirection
          redirect_to = response["Location"]
        else
          # Never returns: every non-success branch raises, with whatever the
          # upstream said about its refusal.
          handle_response(response, url: url, redirects_left: 0, headers: headers, max_bytes: max_bytes,
            error_body: drain_capped(response))
        end
      end
    end

    UpstreamCircuitBreaker.reset!(key)
    if redirect_to.present?
      raise error_class.new("#{service_name}: too many redirects") if redirects_left <= 0

      target = URI.join(url, redirect_to).to_s
      return http_get_file(target, into: into, max_bytes: max_bytes,
        headers: headers_for_redirect(headers, from: url, to: target),
        redirects_left: redirects_left - 1, read_timeout: read_timeout)
    end
    T.must(result)
  rescue *URI_ERRORS => e
    into.delete if into.exist?
    raise error_class.new("#{service_name}: unusable URL: #{e.message.to_s.truncate(120)}")
  rescue *NETWORK_ERRORS => e
    UpstreamCircuitBreaker.trip!(circuit_key(url))
    into.delete if into.exist?
    raise error_class.new("Could not reach #{service_name}: #{e.class}: #{e.message}", connection: true)
  rescue Error
    into.delete if into.exist?
    raise
  end

  private

  # Caller-supplied headers can carry credentials — a Bearer, a Cookie — and
  # following a redirect used to re-send them to whatever host Location named:
  # the standard cross-origin credential-leak shape. Same-host redirects keep
  # everything; a different host loses the sensitive ones. (authorize_request
  # still runs per hop — clients that use it talk to fixed API hosts — so
  # explicit headers are the surface that matters here.)
  SENSITIVE_HEADERS = T.let(%w[authorization cookie proxy-authorization].freeze,
    T::Array[String])

  sig do
    params(headers: T::Hash[String, String], from: String, to: String)
      .returns(T::Hash[String, String])
  end
  def headers_for_redirect(headers, from:, to:)
    return headers if URI.parse(from).host.to_s.downcase == URI.parse(to).host.to_s.downcase

    headers.reject { |name, _| SENSITIVE_HEADERS.include?(name.to_s.downcase) }
  rescue URI::InvalidURIError
    headers.reject { |name, _| SENSITIVE_HEADERS.include?(name.to_s.downcase) }
  end

  # What goes before anything is sent, whatever is sent: guard the address,
  # ask the breaker, build the request and sign it.
  sig do
    params(url: String, headers: T::Hash[String, String], build: T.proc.params(uri: URI::HTTP).returns(::Net::HTTPRequest))
      .returns([ URI::HTTP, ::Net::HTTPRequest, T.untyped, String ])
  end
  def prepare_request(url, headers:, &build)
    pinned = guard_address!(url)
    key = circuit_key(url)
    refuse_if_open!(key)

    uri = T.cast(URI.parse(url), URI::HTTP)
    request = build.call(uri)
    request["User-Agent"] = user_agent
    headers.each { |name, value| request[name] = value }
    authorize_request(request)
    [ uri, request, pinned, key ]
  end

  # The pipeline every verb shares: guard the address, ask the breaker, build
  # the request, send it with capped streaming reads, then turn the answer
  # into a Response or a typed error. Named so it cannot collide with an
  # includer's own methods — a job that includes this module has a `perform`.
  sig do
    params(url: String, headers: T::Hash[String, String], max_bytes: Integer, read_timeout: T.nilable(Integer),
      redirects_left: Integer, build: T.proc.params(uri: URI::HTTP).returns(::Net::HTTPRequest))
      .returns(UpstreamHttpClient::Response)
  end
  def upstream_request(url, headers:, max_bytes:, read_timeout: nil, redirects_left: 0, &build)
    uri, request, pinned, key = prepare_request(url, headers: headers, &build)

    response, body, error_body = transmit(uri, request, pinned: pinned, max_bytes: max_bytes, read_timeout: read_timeout)
    UpstreamCircuitBreaker.reset!(key)
    handle_response(response, url: url, redirects_left: redirects_left, headers: headers, max_bytes: max_bytes,
      body: body, error_body: error_body)
  rescue *URI_ERRORS => e
    raise error_class.new("#{service_name}: unusable URL: #{e.message.to_s.truncate(120)}")
  rescue *NETWORK_ERRORS => e
    UpstreamCircuitBreaker.trip!(circuit_key(url))
    raise error_class.new("Could not reach #{service_name}: #{e.class}: #{e.message}", connection: true)
  end

  # The success half of http_get_file: the declared length is checked against
  # the cap before a byte is taken, and the running count after every chunk.
  sig { params(response: ::Net::HTTPResponse, into: Pathname, max_bytes: Integer, url: String).returns(UpstreamHttpClient::FileDownload) }
  def stream_to_file(response, into, max_bytes:, url:)
    declared = response["Content-Length"]&.to_i
    if declared && declared > max_bytes
      raise error_class.new("#{service_name}: #{declared} bytes exceeds the #{max_bytes}-byte cap")
    end

    written = 0
    deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + file_deadline
    into.open("wb") do |file|
      response.read_body do |chunk|
        check_deadline!(deadline_at, budget: file_deadline)
        written += chunk.bytesize
        raise error_class.new("#{service_name}: download exceeded the #{max_bytes}-byte cap") if written > max_bytes

        file.write(chunk)
      end
    end
    FileDownload.new(status: response.code.to_i, path: into, byte_size: written,
      content_type: response["Content-Type"], final_url: url,
      headers: response.each_header.to_h { |name, value| [ name.downcase, value.to_s ] })
  end

  sig { params(key: String).void }
  def refuse_if_open!(key)
    return unless UpstreamCircuitBreaker.open?(key)

    raise error_class.new("#{service_name} is unreachable — retrying automatically within a minute", connection: true)
  end

  # Streamed rather than fetched whole. Net::HTTP's ordinary form buffers the
  # entire response before anyone can object to its size, so a cap applied
  # after the fact caps what we keep, not what we take — and a host that
  # answers with two gigabytes would take the worker with it.
  sig do
    params(uri: URI::HTTP, request: ::Net::HTTPRequest, pinned: T.nilable(String), max_bytes: Integer,
      read_timeout: T.nilable(Integer)).returns([ T.untyped, T.nilable(String), T.nilable(String) ])
  end
  def transmit(uri, request, pinned:, max_bytes:, read_timeout:)
    response = T.let(nil, T.untyped)
    body = T.let(nil, T.nilable(String))
    error_body = T.let(nil, T.nilable(String))
    ::Net::HTTP.start(
      T.must(uri.host), uri.port,
      use_ssl: uri.scheme == "https", open_timeout: open_timeout,
      read_timeout: read_timeout || self.read_timeout, ipaddr: pinned
    ) do |http|
      http.request(request) do |streamed|
        response = streamed
        if streamed.is_a?(::Net::HTTPSuccess)
          body = read_capped(streamed, max_bytes)
        else
          # Error branches never read their body, but Net::HTTP buffers
          # whatever the block leaves — a hostile 500 can carry gigabytes as
          # easily as a 200 can. Drain a diagnostic allowance and keep it:
          # that allowance is where an upstream explains itself.
          error_body = drain_capped(streamed)
        end
      end
    end
    [ response, body, error_body ]
  end

  sig do
    params(
      response: ::Net::HTTPResponse, url: String, redirects_left: Integer,
      headers: T::Hash[String, String], max_bytes: Integer, body: T.nilable(String),
      error_body: T.nilable(String)
    ).returns(UpstreamHttpClient::Response)
  end
  def handle_response(response, url:, redirects_left:, headers:, max_bytes:, body: nil, error_body: nil)
    case response
    when ::Net::HTTPSuccess
      Response.new(
        status: response.code.to_i, body: decoded_body(response, body.to_s, max_bytes),
        content_type: response["Content-Type"], url: url
      )
    when ::Net::HTTPRedirection
      location = response["Location"]
      if redirects_left <= 0 || location.blank?
        raise error_class.new("#{service_name}: too many redirects", status: response.code.to_i)
      end

      target = URI.join(url, location).to_s
      http_get(target, headers: headers_for_redirect(headers, from: url, to: target),
        redirects_left: redirects_left - 1, max_bytes: max_bytes)
    when ::Net::HTTPTooManyRequests
      detail = upstream_detail(error_body, response)
      raise error_class.rate_limited.new("#{service_name} rate limited this request#{suffix(detail)}",
        status: 429, detail: detail)
    when ::Net::HTTPUnauthorized, ::Net::HTTPForbidden
      detail = upstream_detail(error_body, response)
      raise error_class.unauthorized.new("#{service_name} rejected our credentials#{suffix(detail)}",
        status: response.code.to_i, detail: detail)
    else
      detail = upstream_detail(error_body, response)
      raise error_class.new("#{service_name} returned #{response.code}#{suffix(detail)}",
        status: response.code.to_i, detail: detail)
    end
  end

  sig { params(detail: T.nilable(String)).returns(String) }
  def suffix(detail) = detail.present? ? " — #{detail}" : ""

  # The sentence an upstream volunteered about its own refusal, if it
  # volunteered one. JSON APIs put it under "message" (a string, or an array
  # of them for field validation), "error", or — the house envelope, Hook's
  # — "errors"; anything else falls back to the first line of text. Bounded hard: this ends up in an Activity summary and
  # on the settings screen, not in a log nobody reads.
  DETAIL_LIMIT = T.let(300, Integer)

  sig { params(raw: T.nilable(String), response: ::Net::HTTPResponse).returns(T.nilable(String)) }
  def upstream_detail(raw, response)
    text = raw.to_s
    return nil if text.blank?

    text = inflate(text, ERROR_BODY_ALLOWANCE) if response["Content-Encoding"].to_s.downcase.include?("gzip")
    text = text.dup.force_encoding(Encoding::UTF_8).scrub.strip
    return nil if text.blank?

    parsed = begin
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
    message =
      if parsed.is_a?(Hash)
        value = parsed["message"].presence || parsed["error"].presence || parsed["errors"].presence || parsed["detail"].presence
        value.is_a?(Array) ? value.map(&:to_s).join("; ") : value.to_s
      else
        # Not JSON: an HTML error page is noise, not an explanation.
        text.start_with?("<") ? "" : text.lines.first.to_s
      end
    message.to_s.squish.presence&.truncate(DETAIL_LIMIT)
  rescue StandardError
    # Reporting the original failure always beats failing to describe it.
    nil
  end

  # For branches that never use their body: consume a small diagnostic
  # allowance so Net::HTTP doesn't buffer the rest, then stop. Stopping
  # mid-stream requires an exception (read_body has no early exit); the
  # connection is torn down by the surrounding start block, which is the
  # point — we were done with it.
  ERROR_BODY_ALLOWANCE = T.let(64 * 1024, Integer)

  class TruncatedRead < StandardError; end

  # Returns what it drained. The allowance was always read; throwing it away
  # was the mistake — an upstream that answers 403 with
  # {"message":"Missing permission: library_upload"} has named the fix, and
  # reporting only "rejected our credentials" sends the operator to re-check
  # a password that was never wrong.
  sig { params(response: ::Net::HTTPResponse).returns(T.nilable(String)) }
  def drain_capped(response)
    deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + body_deadline
    buffer = +"".b
    begin
      response.read_body do |chunk|
        check_deadline!(deadline_at, budget: body_deadline)
        buffer << chunk
        raise TruncatedRead if buffer.bytesize > ERROR_BODY_ALLOWANCE
      end
    rescue TruncatedRead
      nil
    end
    buffer.presence
  end

  # Reads the body chunk by chunk, refusing to hold more than the cap.
  #
  # The cap is a refusal rather than a truncation: every caller here parses
  # XML or JSON, and half a document fails to parse anyway — truncating turned
  # "this answer is enormous" into "this answer is malformed", which is a
  # worse thing to read at 2am and a worse thing to act on.
  #
  # Binary, deliberately, and forced rather than assumed: appending a string to
  # an empty binary buffer adopts the *argument's* encoding, so a chunk that
  # arrives tagged UTF-8 while holding gzip promotes the whole buffer with it.
  # Bytes off the wire are bytes until decoded_body says otherwise.
  sig { params(response: ::Net::HTTPResponse, max_bytes: Integer).returns(String) }
  def read_capped(response, max_bytes)
    deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + body_deadline
    buffer = +"".b
    response.read_body do |chunk|
      check_deadline!(deadline_at, budget: body_deadline)
      buffer << chunk
      if buffer.bytesize > max_bytes
        raise error_class.new("#{service_name}: response exceeds the #{max_bytes}-byte cap")
      end
    end
    buffer.force_encoding(Encoding::BINARY)
  end

  sig { params(deadline_at: T.any(Float, Integer), budget: Integer).void }
  def check_deadline!(deadline_at, budget:)
    return if Process.clock_gettime(Process::CLOCK_MONOTONIC) <= deadline_at

    raise DeadlineExceeded, "#{service_name}: body still arriving after #{budget}s — abandoning " \
                            "a connection that trickles instead of finishing"
  end

  sig { params(response: ::Net::HTTPResponse, raw: String, max_bytes: Integer).returns(String) }
  def decoded_body(response, raw, max_bytes)
    decoded =
      if response["Content-Encoding"].to_s.downcase.include?("gzip") && raw.present?
        inflate(raw, max_bytes)
      else
        raw
      end
    decoded.byteslice(0, max_bytes).to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end

  # Inflating is where the cap on the wire stops meaning anything: compression
  # ratios above 1000:1 are trivial to produce, so ten megabytes of gzip that
  # passed read_capped can still be gigabytes once expanded. Reading the stream
  # in chunks means the ceiling is enforced during expansion rather than
  # discovered after it.
  sig { params(raw: String, max_bytes: Integer).returns(String) }
  def inflate(raw, max_bytes)
    reader = Zlib::GzipReader.new(StringIO.new(raw))
    out = +"".b
    while (chunk = reader.read(BODY_CHUNK_BYTES))
      out << chunk
      if out.bytesize > max_bytes
        raise error_class.new(
          "#{service_name}: compressed response expands past the #{max_bytes}-byte cap"
        )
      end
    end
    out.force_encoding(Encoding::BINARY)
  rescue Zlib::Error
    # Not gzip after all, whatever the header claimed. Hand back what arrived
    # rather than failing on a mislabelled body.
    raw
  end

  class FileDownload < T::Struct
    const :status, Integer
    const :path, Pathname
    const :byte_size, Integer
    # As sent by the server, parameters included.
    const :content_type, T.nilable(String), default: nil
    const :final_url, String
    # The response's own headers, keys downcased as Net::HTTP reports them.
    # A streamed body is never in hand to inspect, so anything the server said
    # *about* the bytes — a content digest, most of all — has nowhere else to
    # arrive.
    const :headers, T::Hash[String, String], default: {}
  end

  class Response < T::Struct
    const :status, Integer
    const :body, T.nilable(String)
    # As sent by the server, parameters included ("text/html; charset=utf-8").
    const :content_type, T.nilable(String), default: nil
    const :url, String
  end
end
