# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # One integration's settings in Settings (CLAUDE.md, configuration
    # belongs in the UI): read, saved, removed and tested the same way for
    # each. Its secrets are write-only — a blank one keeps what's saved.
    # A subclass names its setting, its fields and how it's tested. (Not
    # Rails-abstract: that would keep these actions from its routes.)
    class IntegrationSettingsController < BaseController
      before_action :require_admin!

      sig { void }
      def show
        render json: json_for(setting_class.find_by(household: current_household!))
      end

      sig { void }
      def update
        setting = setting_class.find_or_initialize_by(household: current_household!)
        changes = permitted
        write_only.each do |field, when_blank|
          changes.delete(field) if changes[field].blank? && (when_blank == :always_kept || setting.persisted?)
        end
        setting.assign_attributes(changes)
        setting.save!
        saved(setting)
        render json: json_for(setting)
      end

      sig { void }
      def destroy
        setting_class.where(household: current_household!).destroy_all
        render json: json_for(nil)
      end

      sig { void }
      def test
        setting = setting_class.find_by(household: current_household!)
        return render json: { ok: false, message: unsaved_message } if setting.nil? || !testable?(setting)

        ok, message = client(setting).test_connection
        setting.record_test!(ok, message)
        render json: { ok: ok, message: message }
      end

      private

      sig { returns(T.untyped) }
      def setting_class = raise NotImplementedError

      # The fields a save may change.
      sig { returns(T::Hash[String, T.untyped]) }
      def permitted = raise NotImplementedError

      # Secret fields: a blank one keeps the saved value once there is one,
      # or always (:always_kept).
      sig { returns(T::Hash[String, Symbol]) }
      def write_only = {}

      sig { params(setting: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(setting) = raise NotImplementedError

      # What follows a save (its saved_changes still readable).
      sig { params(setting: T.untyped).void }
      def saved(setting); end

      # Whether a saved setting has enough to test; unsaved_message if not.
      sig { params(setting: T.untyped).returns(T::Boolean) }
      def testable?(setting) = true

      # What answers test_connection for it.
      sig { params(setting: T.untyped).returns(T.untyped) }
      def client(setting) = raise NotImplementedError

      sig { returns(String) }
      def unsaved_message = raise NotImplementedError
    end
  end
end
