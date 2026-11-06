# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The watching profile's pushes (PROPOSAL §7.4): its ntfy topic and what
    # it wants to hear about.
    class NotificationPreferencesController < BaseController
      sig { void }
      def show
        render json: preferences_json
      end

      sig { void }
      def update
        profile = current_profile!
        changes = params.permit(:ntfy_topic, :notify_new_episodes, :notify_subscriptions).to_h
        changes["ntfy_topic"] = changes["ntfy_topic"].to_s.strip.presence if changes.key?("ntfy_topic")
        if changes["ntfy_topic"] && !changes["ntfy_topic"].to_s.match?(/\A[\w-]{1,64}\z/)
          return render_errors("A topic is letters, numbers, - and _")
        end

        profile.update!(changes)
        render json: preferences_json
      end

      sig { void }
      def test
        base = NtfyClient.base_url
        topic = current_profile!.ntfy_topic
        return render json: { ok: false, message: "No ntfy server is set up (Settings › General)." } if base.nil?
        return render json: { ok: false, message: "Choose a topic first." } if topic.blank?

        NtfyClient.new(base_url: base, topic: topic).publish(title: "Stream", message: "Notifications for #{current_profile!.name} work.")
        render json: { ok: true, message: "Sent — check ntfy." }
      rescue UpstreamHttpClient::Error => e
        render json: { ok: false, message: e.message }
      end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def preferences_json
        profile = current_profile!
        {
          ntfy_topic: profile.ntfy_topic, notify_new_episodes: profile.notify_new_episodes,
          notify_subscriptions: profile.notify_subscriptions, ntfy_configured: !NtfyClient.base_url.nil?
        }
      end
    end
  end
end
