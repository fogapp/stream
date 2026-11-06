# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class InvitesController < BaseController
      skip_before_action :require_auth, only: :accept
      before_action :require_admin!, only: :create

      rate_limit to: 10, within: 3.minutes, only: :accept

      sig { void }
      def create
        role = User::Role.try_deserialize(params[:role].to_s) || User::Role::Member
        invite = InviteCode.generate!(household: current_household!, created_by: current_user!, role: role)
        render json: { code: invite.code, role: invite.role, expires_at: invite.expires_at }, status: :created
      end

      sig { void }
      def accept
        # An invite makes a password account; on fog, people arrive through
        # fog instead (the app's Sign-in tab there decides who may).
        return render_errors("Stream signs people in with fog", status: :forbidden) if FogSignin.fog_only?

        invite = InviteCode.find_by(code: params.require(:code).to_s)
        return render_errors("Invite is invalid or expired", status: :unprocessable_content) unless invite&.usable?

        household = T.cast(invite.household, Household)
        ActiveRecord::Base.transaction do
          user = household.users.create!(
            email: params.require(:email).to_s,
            name: params.require(:name).to_s,
            password: params.require(:password).to_s,
            role: invite.role
          )
          invite.consume!
          session = ApiSession.generate!(user: user, device: "invite")
          render json: { token: session.token, user: UserSerializer.user_json(user) }, status: :created
        end
      rescue InviteCode::AlreadyUsed
        render_errors("Invite is invalid or expired", status: :unprocessable_content)
      end
    end
  end
end
