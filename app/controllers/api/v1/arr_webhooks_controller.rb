# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Integrations › Sonarr & Radarr: the webhook URL to paste
    # into each app's Connect settings, and the path mappings between them.
    class ArrWebhooksController < BaseController
      before_action :require_admin!

      sig { void }
      def show
        render json: json_for(ArrWebhook.for(current_household!))
      end

      sig { void }
      def regenerate
        webhook = ArrWebhook.for(current_household!)
        webhook.regenerate!
        render json: json_for(webhook)
      end

      sig { void }
      def create_mapping
        PathMapping.create!(params.require(:path_mapping).permit(:remote_prefix, :local_prefix))
        render json: json_for(ArrWebhook.for(current_household!)), status: :created
      end

      sig { void }
      def destroy_mapping
        PathMapping.find(params.require(:mapping_id)).destroy!
        render json: json_for(ArrWebhook.for(current_household!))
      end

      private

      sig { params(webhook: ArrWebhook).returns(T::Hash[Symbol, T.untyped]) }
      def json_for(webhook)
        {
          url: "#{request.base_url}/hooks/arr/#{webhook.token}",
          last_received_at: webhook.last_received_at, last_source: webhook.last_source,
          last_event: webhook.last_event, last_outcome: webhook.last_outcome,
          path_mappings: PathMapping.order(:remote_prefix).map do |mapping|
            { id: mapping.id, remote_prefix: mapping.remote_prefix, local_prefix: mapping.local_prefix }
          end
        }
      end
    end
  end
end
