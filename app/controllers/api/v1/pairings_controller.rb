# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Device-code pairing (PROPOSAL §7.4): a TV starts one and polls it, and
    # someone signed in approves its code. Starting and polling need no
    # session — that's the point — so both are rate-limited and the poll
    # needs the secret the TV was given, not the code on its screen.
    class PairingsController < BaseController
      skip_before_action :require_auth, only: %i[create show]
      skip_before_action :set_current_profile, only: %i[create show]
      skip_before_action :deny_guest_writes, only: %i[create show]

      STARTS_PER_WINDOW = 10
      WINDOW = T.let(10.minutes, ActiveSupport::Duration)

      sig { void }
      def create
        key = "pairing_starts:#{request.remote_ip}"
        count = Rails.cache.increment(key, 1, expires_in: WINDOW) || 1
        return render_errors("Too many codes asked for; wait a few minutes", status: :too_many_requests) if count > STARTS_PER_WINDOW

        # A native client can say what it is ("Apple TV (Living Room)");
        # a browser is named from its user agent.
        label = params[:device_label].to_s.strip.first(60).presence || Device.name_from(request.user_agent.to_s)
        pairing = DevicePairing.start!(label)
        render json: { code: pairing.display_code, poll_token: pairing.poll_token, expires_at: pairing.expires_at }, status: :created
      end

      # The TV's poll: pending, or — once, then never again — its session.
      sig { void }
      def show
        pairing = DevicePairing.find_by!(poll_token: params.require(:id).to_s)
        return render_errors("That code has expired; start again", status: :gone) if pairing.expired? && pairing.state_enum == DevicePairing::State::Pending
        return render json: { state: "pending" } if pairing.state_enum == DevicePairing::State::Pending
        return render_errors("Already signed in with this code", status: :gone) if pairing.state_enum == DevicePairing::State::Collected

        token = pairing.session_token.to_s
        user = T.must(pairing.user)
        pairing.update!(state: DevicePairing::State::Collected.serialize, session_token: nil)
        render json: { state: "approved", token: token, user: UserSerializer.user_json(user) }
      end

      # { code }: someone signed in says this TV is theirs.
      sig { void }
      def approve
        pairing = DevicePairing.find_by(code: DevicePairing.normalize(params.require(:code).to_s), state: DevicePairing::State::Pending.serialize)
        return render_errors("That code isn't right, or it has expired", status: :not_found) if pairing.nil? || pairing.expired?

        user = current_user!
        session = ApiSession.generate!(user: user, device: "TV — #{pairing.device_label}")
        pairing.update!(state: DevicePairing::State::Approved.serialize, user: user, household_id: user.household_id,
          session_token: session.token)
        Activity.record(source: "auth", event: "device.paired", subject: user, household_id: user.household_id,
          summary: "#{user.name} signed in a TV (#{pairing.device_label}) with a code")
        render json: { device: pairing.device_label }
      end
    end
  end
end
