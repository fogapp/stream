# typed: strict
# frozen_string_literal: true

# Authenticated surface base. Public endpoints (health, the SPA shell, the
# /fog/* contract surface) deliberately do NOT inherit from this — they sit
# outside the bearer-token stack.
#
# Two credential kinds resolve to a User: an ApiSession (interactive login)
# or a user-minted ApiToken (`stream_` prefix — integrations and scripts).
#
# A read-scoped token is refused every non-GET request here, once, before
# any controller runs: the only writes it may make are the POSTs that are
# queries in disguise (a station preview, a YouTube URL lookup), which their
# controllers open with `allow_read_scope`.
class ApplicationController < ActionController::API
  extend T::Sig

  include BearerToken

  before_action :set_trace_id
  before_action :require_auth
  before_action :deny_read_scope_writes

  class_attribute :read_scope_actions, instance_accessor: false, default: T.let([].freeze, T::Array[String])

  sig { params(actions: Symbol).void }
  def self.allow_read_scope(*actions)
    self.read_scope_actions = (read_scope_actions + actions.map(&:to_s)).freeze
  end

  private

  sig { void }
  def set_trace_id
    Current.trace_id = request.request_id
  end

  sig { void }
  def require_auth
    token = bearer_token
    api_token = ApiToken.authenticate(token)
    if api_token
      api_token.record_use!
      user = T.cast(api_token.user, User)
      Current.user = user
      Current.household = user.household
      Current.api_token = api_token
      return
    end

    session = current_api_session
    return render(json: { errors: [ "unauthorized" ] }, status: :unauthorized) if session.nil?

    user = T.cast(session.user, User)
    Current.user = user
    Current.household = user.household
    Current.api_session = session
    session.record_use!
  end

  # Read tokens are for looking: every non-GET action is closed to them
  # unless the controller opened it with `allow_read_scope`.
  sig { void }
  def deny_read_scope_writes
    token = Current.api_token
    return unless token.is_a?(ApiToken) && token.read_only?
    return if request.get? || request.head?
    return if self.class.read_scope_actions.include?(action_name.to_s)

    render json: { errors: [ "This token is read-only" ] }, status: :forbidden
  end

  sig { returns(T.nilable(ApiSession)) }
  def current_api_session
    @current_api_session = T.let(@current_api_session, T.nilable(ApiSession))
    return @current_api_session if @looked_up_session

    @looked_up_session = T.let(true, T.nilable(T::Boolean))
    token = bearer_token
    @current_api_session = token.present? && !token.start_with?(ApiToken::PREFIX) ? ApiSession.live(token) : nil
  end

  # The typed boundary over CurrentAttributes' untyped accessors — call these
  # rather than Current.user/.household so the rest of app/ stays typed.
  #
  # Protected, not private: `finds` lambdas are instance_exec'd and reference
  # them with an explicit receiver, which Ruby forbids for private methods.
  # Protected still keeps them out of Rails' action list.
  protected

  sig { returns(User) }
  def current_user! = T.cast(Current.user, User)

  sig { returns(Household) }
  def current_household! = T.cast(Current.household, Household)
end
