# typed: strict
# frozen_string_literal: true

# The ntfy push relay, through the shared client like every other egress, so
# it gets the same timeouts, circuit breaker and typed errors. Publishes as
# JSON to the server root (ntfy's "publish as JSON"), which carries the topic
# and title in the body rather than in the path and headers.
class NtfyClient
  extend T::Sig
  include UpstreamHttpClient

  class Error < UpstreamHttpClient::Error; end

  sig { params(base_url: String, topic: String).void }
  def initialize(base_url:, topic:)
    @base_url = base_url
    @topic = topic
  end

  sig { override.returns(String) }
  def service_name = "ntfy"

  sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
  def error_class = Error

  # NTFY_URL is fog's ntfy on the fog network, injected at boot — a private
  # address by design, not a URL handed to Stream by content.
  sig { override.returns(T::Boolean) }
  def allow_private_addresses? = true # rubocop:disable Stream/NoUnreviewedPrivateEgress

  # A push is a nicety on top of the durable in-app row; a relay that can't
  # answer in three seconds isn't worth holding a worker for.
  sig { returns(Integer) }
  def open_timeout = 3

  sig { returns(Integer) }
  def read_timeout = 3

  sig { params(title: String, message: String, click: T.nilable(String)).void }
  def publish(title:, message:, click: nil)
    body = { topic: @topic, title: title, message: message }
    body[:click] = click if click
    http_post_json("#{@base_url.chomp('/')}/", body: body)
  end

  # The household's ntfy: set in Settings › General, else NTFY_URL.
  sig { returns(T.nilable(String)) }
  def self.base_url = AppSetting.cached.ntfy_url.presence || ENV["NTFY_URL"].presence
end
