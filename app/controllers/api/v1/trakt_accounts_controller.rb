# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The watching profile's Trakt link (PROPOSAL §7.4), made with a device
    # code: start, then poll while the code is on screen. Kid profiles don't
    # link Trakt.
    class TraktAccountsController < BaseController
      before_action :refuse_kids

      sig { void }
      def show
        render json: account_json
      end

      sig { void }
      def create
        Trakt::Linking.start(current_profile!)
        render json: account_json, status: :created
      rescue Trakt::Linking::NotSetUp => e
        render_errors(e.message, status: :conflict)
      rescue UpstreamHttpClient::Error => e
        render_errors("Trakt didn't give a code: #{e.message}", status: :bad_gateway)
      end

      sig { void }
      def poll
        account = TraktAccount.find_by(profile: current_profile!)
        return head(:not_found) if account.nil?

        Trakt::Linking.poll(account)
        render json: account_json
      rescue UpstreamHttpClient::Error => e
        render_errors("Couldn't reach Trakt: #{e.message}", status: :bad_gateway)
      end

      sig { void }
      def sync
        account = TraktAccount.linked.find_by(profile: current_profile!)
        return render_errors("This profile isn't linked to Trakt", status: :conflict) if account.nil?

        TraktPushJob.perform_later(account.id)
        TraktPullJob.perform_later(account.id)
        render json: account_json, status: :accepted
      end

      sig { void }
      def destroy
        account = TraktAccount.find_by(profile: current_profile!)
        Trakt::Linking.unlink(account) if account
        render json: account_json
      end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def account_json
        TraktSerializer.account_json(available: TraktSetting.exists?(household: current_household!),
          account: TraktAccount.find_by(profile: current_profile!))
      end

      sig { void }
      def refuse_kids
        render_errors("Kid profiles don't link Trakt", status: :forbidden) if current_profile!.kid?
      end
    end
  end
end
