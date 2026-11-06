# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class SessionsController < BaseController
      skip_before_action :require_auth, only: :create
      # Signing in and out is a guest's own business.
      skip_before_action :deny_guest_writes

      # Rails 8 native rate limiting (hub pattern).
      rate_limit to: 10, within: 3.minutes, only: :create

      sig { void }
      def create
        return render_errors("Stream signs people in with fog", status: :forbidden) if FogSignin.fog_only?

        user = User.find_by(email: params.require(:email).to_s.strip.downcase)
        if user&.authenticate(params.require(:password).to_s)
          session = ApiSession.generate!(user: user, device: params[:device].presence&.to_s)
          render json: { token: session.token, user: UserSerializer.user_json(user) }, status: :created
        else
          render_errors("Invalid email or password", status: :unauthorized)
        end
      end

      sig { void }
      def destroy
        Current.api_session&.destroy
        head :no_content
      end
    end
  end
end
