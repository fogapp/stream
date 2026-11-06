# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # First-run wizard endpoint for fresh fog deploys: creates the household +
    # first admin, exactly once. After any user exists this endpoint is a 403
    # and members join by invite only.
    class SetupController < BaseController
      skip_before_action :require_auth

      rate_limit to: 5, within: 10.minutes, only: %i[create restore]

      # How the console should sign people in: Stream's own wizard and
      # passwords, fog alongside them, or fog alone (FogSignin).
      sig { void }
      def show
        FogSignin.attest_if_needed
        render json: {
          setup_required: User.count.zero? && !FogSignin.fog_only?,
          signin: { enabled: FogSignin.enabled?, fog_only: FogSignin.fog_only? }
        }
      end

      # The wizard's other door (fog-backup/2): instead of creating a fresh
      # household, upload a backup artifact and recover the previous instance.
      # Same once-only guard as create — after any user exists this is a 403.
      # On success the artifact is staged and armed; the app restarts itself
      # and the entrypoint performs the restore before serving again.
      sig { void }
      def restore
        return render_errors("Setup already completed", status: :forbidden) if User.exists?
        # On fog the wizard is off; fog restores its apps through fog-backup/2.
        return render_errors("Sign in with fog to set Stream up", status: :forbidden) if FogSignin.fog_only?

        upload = params[:artifact]
        unless upload.respond_to?(:tempfile)
          return render_errors("Provide a backup artifact file", status: :bad_request)
        end

        FogBackup::Staging.restore_root.mkpath
        FileUtils.mv(T.unsafe(upload).tempfile.path, FogBackup::Staging.pending_artifact.to_s)

        confirm = bool_param(:confirm_identity)
        preflight = FogBackup::Preflight.check(
          artifact_path: FogBackup::Staging.pending_artifact,
          confirm_identity: confirm
        )
        unless preflight.ok?
          FogBackup::Staging.disarm!
          return render json: { errors: preflight.errors, preflight: FogSerializer.preflight_json(preflight) },
            status: :unprocessable_content
        end

        FogBackup::Staging.arm!(confirm_identity: confirm, staged_by: "setup-wizard")
        Activity.record(
          source: "fog", event: "backup.restore.armed",
          summary: "Restore armed from the setup wizard — restarting to recover"
        )
        FogBackup::Restart.schedule!
        render json: { restarting: true, preflight: FogSerializer.preflight_json(preflight) }
      end

      sig { void }
      def create
        return render_errors("Setup already completed", status: :forbidden) if User.exists?
        # On fog the first sign-in is the setup: the operator signs in and
        # is the admin.
        return render_errors("Sign in with fog to set Stream up", status: :forbidden) if FogSignin.fog_only?

        ActiveRecord::Base.transaction do
          household = Household.create!(name: params.require(:household_name).to_s)
          user = household.users.create!(
            email: params.require(:email).to_s,
            name: params.require(:name).to_s,
            password: params.require(:password).to_s,
            role: User::Role::Admin.serialize
          )
          session = ApiSession.generate!(user: user, device: "setup")
          render json: { token: session.token, user: UserSerializer.user_json(user) }, status: :created
        end
      end
    end
  end
end
