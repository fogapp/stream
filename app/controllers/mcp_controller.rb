# typed: strict
# frozen_string_literal: true

# The MCP surface (PROPOSAL §11 Phase 6): an agent can be asked "play the
# next episode of Severance in the living room" and Stream does it.
# Outside the console auth stack like hook's: the credential is an ApiToken
# (revocable per agent), never an ApiSession. A fresh MCP::Server per
# request over stateless Streamable HTTP in JSON mode, so nothing survives a
# request and fog's overlapping replicas need no session affinity.
#
# A read-scoped token (ApiToken::Scope) is handed only the tools that look
# (Mcp::Toolbox.for), and a call it makes to one that changes things is
# refused in the same shape as a call to a tool that does not exist.
class McpController < ActionController::API
  extend T::Sig

  include BearerToken

  SERVER_VERSION = "1.0.0"

  INSTRUCTIONS = <<~TEXT
    Stream is this household's video player: films, shows, the YouTube
    channels it keeps, home videos, and live cameras and streams. Call `whoami` first: it names the
    profiles (whose watch history counts) and the screens listening now.
    `search` finds titles; `next_up` says what a profile would watch next;
    `play_on_screen` starts something on a listening screen, and
    `control_screen` pauses, resumes, seeks or stops it. Grid is
    channels made from the library on a schedule: `whats_on` lists what
    each is airing, and `tune_channel` puts one on a screen. Cameras and
    web streams are `live_streams`; `play_on_screen` with `stream` puts one
    on a screen by name. Starting playback changes what's on someone's
    screen — only do it when asked.
  TEXT

  before_action :set_trace_id
  before_action :authenticate!
  after_action :reset_current

  sig { void }
  def handle
    server = MCP::Server.new(
      name: "stream", title: "Stream", version: SERVER_VERSION, instructions: INSTRUCTIONS,
      tools: Mcp::Toolbox.for(current_token),
      server_context: { user: Current.user, household: Current.household, token: current_token },
      configuration: mcp_configuration
    )
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server, stateless: true, enable_json_response: true,
      # Bearer auth already gates every request; fog's proxy owns Host routing.
      dns_rebinding_protection: false
    )
    status, headers, body = transport.handle_request(request)
    headers&.each { |key, value| response.set_header(key, value) }

    payload = body.respond_to?(:first) ? body.first : nil
    if payload.present?
      render json: payload, status: status
    else
      head status
    end
  end

  private

  sig { void }
  def set_trace_id
    Current.trace_id = request.request_id
  end

  sig { void }
  def authenticate!
    token = ApiToken.authenticate(bearer_token)
    if token.nil?
      response.set_header("WWW-Authenticate", 'Bearer realm="Stream MCP"')
      return render(json: { errors: [ "unauthorized" ] }, status: :unauthorized)
    end

    token.record_use!
    @token = T.let(token, T.nilable(ApiToken))
    user = T.cast(token.user, User)
    Current.user = user
    Current.household = user.household
    Current.api_token = token
  end

  sig { returns(ApiToken) }
  def current_token = T.must(@token)

  sig { returns(MCP::Configuration) }
  def mcp_configuration
    configuration = MCP::Configuration.new
    configuration.exception_reporter = ->(exception, _context) do
      Activity.record(source: "mcp", event: "mcp.error", severity: Activity::Severity::Error,
        summary: "MCP request failed: #{exception.class}: #{exception.message.to_s.truncate(200)}")
    end
    configuration.around_request = ->(data, &request_handler) do
      refuse_write_with_read_token! if data[:method] == "tools/call"
      result = request_handler.call
      if data[:method] == "tools/call"
        Activity.record(source: "mcp", event: "mcp.tool_call", summary: "Agent called #{data[:tool_name] || 'unknown tool'}",
          payload: { tool: data[:tool_name] })
      end
      result
    end
    configuration
  end

  # The gem learns the tool's name only as it dispatches, so the refusal reads
  # it from the parsed request body. Raised as the gem's own error so the
  # answer is the JSON-RPC error a call to an unknown tool gets.
  sig { void }
  def refuse_write_with_read_token!
    return unless current_token.read_only?

    name = params.dig(:params, :name).to_s
    return unless Mcp::Toolbox.writer?(name)

    # The explicit error_code keeps the sentence; error_type alone would
    # render the generic "Invalid params".
    raise MCP::Server::RequestHandlerError.new(
      "This token is read-only: #{name} changes things, and a read token may only look", {},
      error_type: :invalid_params, error_code: JsonRpcHandler::ErrorCode::INVALID_PARAMS
    )
  end

  sig { void }
  def reset_current
    Current.reset
  end
end
