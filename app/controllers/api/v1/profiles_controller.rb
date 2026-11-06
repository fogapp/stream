# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Who's watching (PROPOSAL §7.4): the household's profiles, choosing one
    # (its PIN checked here, never in the browser), and — for admins —
    # making, changing and removing them.
    class ProfilesController < BaseController
      finds :profile, from: -> { Profile.all }
      skip_before_action :set_profile, only: %i[index create current device_default]
      before_action :require_admin!, only: %i[create destroy]

      # Wrong PINs allowed per profile in a window before it waits.
      PIN_ATTEMPTS = 5
      PIN_WINDOW = T.let(10.minutes, ActiveSupport::Duration)

      sig { void }
      def index
        Profile.default_for(current_household!)
        render json: Profile.order(:position, :created_at).map { |row| ProfileSerializer.json(row) }
      end

      # The profile this browser is on, and whether it should be asked.
      sig { void }
      def current
        Profile.default_for(current_household!)
        chosen = chosen_profile
        device = current_device
        render json: {
          profile: ProfileSerializer.json(current_profile!),
          chosen: !chosen.nil?,
          device_default_id: device&.default_profile_id,
          # More than one profile and nothing chosen here: show the picker.
          needs_picker: chosen.nil? && device&.default_profile_id.nil? && Profile.count > 1
        }
      end

      # { pin } → a token that says this browser chose this profile.
      sig { void }
      def select
        if profile.pin?
          return render_errors("Too many wrong PINs; try again in a few minutes", status: :too_many_requests) if locked_out?
          unless profile.authenticate_pin(params[:pin].to_s)
            record_failure
            return render_errors("That PIN isn't right", status: :unauthorized)
          end
        end
        clear_failures
        if bool_param(:make_default)
          device = current_device(create: true)
          device&.update!(default_profile: profile)
        end
        render json: { token: ProfileTokens.issue(profile), profile: ProfileSerializer.json(profile) }
      end

      sig { void }
      def create
        created = Profile.new(profile_params.merge(restriction_params))
        created.change_pin(params[:pin].presence&.to_s)
        created.position = Profile.maximum(:position).to_i + 1
        created.save!

        render json: ProfileSerializer.json(created), status: :created
      end

      # An admin changes any profile; a profile changes its own (once chosen).
      sig { void }
      def update
        return render_errors("Only an admin can change another profile", status: :forbidden) unless may_change?

        profile.assign_attributes(profile_params)
        # What a profile may see is an admin's to set, never its own.
        profile.assign_attributes(restriction_params) if current_user!.admin?
        profile.change_pin(params[:pin].to_s) if params.key?(:pin)
        profile.save!

        render json: ProfileSerializer.json(profile)
      end

      sig { void }
      def destroy
        return render_errors("A household keeps at least one profile") if Profile.count <= 1

        profile.destroy!
        head :no_content
      end

      # This device's default profile: { profile_id } or none to clear.
      sig { void }
      def device_default
        device = current_device(create: true)
        return render_errors("This browser hasn't said which device it is") if device.nil?

        target = params[:profile_id].presence && Profile.find(params[:profile_id].to_s)
        if target && target.pin? && chosen_profile != target
          return render_errors("Choose that profile (with its PIN) on this device first", status: :forbidden)
        end

        device.update!(default_profile: target || nil)
        render json: { device_default_id: device.default_profile_id }
      end

      private

      sig { returns(T::Hash[String, T.untyped]) }
      def profile_params = params.permit(:name, :color, :avatar).to_h.to_hash

      sig { returns(T::Hash[String, T.untyped]) }
      def restriction_params
        given = params.permit(:kind, :max_rating_age, :allow_unrated, :curated, :up_next_seconds, :always_skip_intro,
          :always_skip_credits, :still_watching_after, library_ids: []).to_h.to_hash
        %w[max_rating_age up_next_seconds still_watching_after].each { |key| given[key] = nil if given.key?(key) && given[key].to_s.empty? }
        given["library_ids"] = Array(given["library_ids"]).compact_blank if given.key?("library_ids")
        given
      end

      sig { returns(T::Boolean) }
      def may_change?
        current_user!.role_enum == User::Role::Admin || chosen_profile == profile
      end

      sig { returns(String) }
      def failure_key = "profile_pin_failures:#{profile.id}"

      sig { returns(T::Boolean) }
      def locked_out? = Rails.cache.read(failure_key).to_i >= PIN_ATTEMPTS

      sig { void }
      def record_failure
        Rails.cache.write(failure_key, Rails.cache.read(failure_key).to_i + 1, expires_in: PIN_WINDOW)
      end

      sig { void }
      def clear_failures = Rails.cache.delete(failure_key)
    end
  end
end
