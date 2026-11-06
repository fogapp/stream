# typed: strict
# frozen_string_literal: true

# Inbound webhooks from the arr stack (PROPOSAL §5.1). Outside /api: the
# caller is Sonarr or Radarr, authenticated by the token in the URL.
class HooksController < ActionController::API
  extend T::Sig

  MAX_BODY = T.let(1.megabyte, Integer)

  # Rails parses a JSON body before the action runs; junk is a 400.
  rescue_from ActionDispatch::Http::Parameters::ParseError, with: :bad_request

  sig { void }
  def arr
    # From the path alone: touching `params` would parse the body first.
    webhook = ArrWebhook.unscoped.find_by(token: request.path_parameters[:token].to_s)
    return head(:not_found) if webhook.nil?
    return head(:payload_too_large) if request.content_length.to_i > MAX_BODY

    payload = JSON.parse(request.raw_post.presence || "{}")
    return head(:bad_request) unless payload.is_a?(Hash)

    outcome = Integrations::ArrEvent.new(webhook, payload).call
    render json: { scanned: outcome.scanned.size, message: outcome.summary }
  rescue JSON::ParserError
    bad_request
  end

  private

  sig { params(_error: T.untyped).void }
  def bad_request(_error = nil)
    head :bad_request
  end
end
