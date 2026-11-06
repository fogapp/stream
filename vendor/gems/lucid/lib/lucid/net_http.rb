# frozen_string_literal: true

require "ipaddr"
require "net/http"
require_relative "bounded_cache"

module Lucid
  # Outbound HTTP as `http` spans, and trace propagation to siblings only.
  # `traceparent` is injected when the target is a private address or a
  # bare hostname (fog's Docker DNS names: http://lucid, http://hook) —
  # never to the public internet, where the header would leak trace ids to
  # third parties for no benefit.
  module NetHttp
    MAX_PATH = 200
    # An address written as one: dotted IPv4, or IPv6 (bracketed or not).
    # Anything else with a dot is a hostname, decided without parsing it.
    IP_LITERAL = /\A(?:\d{1,3}(?:\.\d{1,3}){3}|\[?[0-9a-fA-F:]*:[0-9a-fA-F:.]*\]?)\z/
    # Tailscale / CGNAT: a sibling over the home VPN is ours too.
    CGNAT = IPAddr.new("100.64.0.0/10")
    @propagate = BoundedCache.new(256)

    def self.install!
      return if @installed
      @installed = true
      ::Net::HTTP.prepend(Patch)
    end

    # Asked on every outbound request: remembered per host.
    def self.propagate?(host)
      return false if host.nil? || host.empty?
      @propagate.fetch(host) { ours?(host) }
    end

    def self.ours?(host)
      return true unless host.include?(".") || host.include?(":")
      return false unless IP_LITERAL.match?(host) # a dotted hostname: not ours
      ip = IPAddr.new(host.delete_prefix("[").delete_suffix("]"))
      ip = ip.native if ip.ipv4_mapped?
      ip.loopback? || ip.private? || ip.link_local? || CGNAT.include?(ip)
    rescue IPAddr::Error, ArgumentError
      false
    end
    private_class_method :ours?

    module Patch
      # Net::HTTP#request re-enters itself through #start when the
      # connection is not open yet; only the started call is measured, so
      # one request is one span.
      def request(req, body = nil, &block)
        txn = started? && !Thread.current[:lucid_agent] && Lucid.enabled? ? Lucid::Tracer.current : nil
        return super unless txn && Lucid.config.feature?(:http)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        span = nil
        begin
          host = address.to_s
          name = "#{req.method} #{host}"
          span = txn.start_span("http", name, "#{req.method} #{host}#{req.path.to_s.split('?', 2).first.to_s[0, MAX_PATH]}", start)
          if Lucid::NetHttp.propagate?(host) && !req["traceparent"]
            req["traceparent"] = "00-#{txn.trace_id}-#{txn.span_hex(span)}-01"
          end
        rescue StandardError => e
          Lucid.error("http", e)
        end
        failed = nil
        response = nil
        begin
          response = super
        rescue Exception => e
          failed = e
          raise
        ensure
          begin
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            dur = (now - start) * 1000.0
            txn.ext_ms += dur
            txn.ext_n += 1
            if span
              txn.finish_span(span, now, error: failed || (response && response.code.to_i >= 500))
              span.attrs = { "status" => response.code.to_i } if response
            end
          rescue StandardError => e
            Lucid.error("http", e)
          end
        end
      end
    end
  end
end
