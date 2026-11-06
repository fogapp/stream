# typed: strict
# frozen_string_literal: true

module Api
  module V1
    class NotificationsController < BaseController
      finds :notification, from: -> { T.unsafe(self).current_user!.notifications }
      skip_before_action :set_notification, only: %i[index read_all]

      # Newest first, paged. Every answer carries the unread count; the
      # console's bell asks for one row and reads only that.
      sig { void }
      def index
        rows = paginate(current_user!.notifications.recent, default_per: 50, max_per: 200).to_a
        render json: NotificationSerializer.index_json(rows, unread_count: unread_count)
      end

      # Marking read is idempotent: a row already read keeps its first
      # read_at rather than moving to now.
      sig { void }
      def read
        notification.update!(read_at: Time.current) if notification.read_at.nil?
        render json: NotificationSerializer.notification_json(notification).merge(unread_count: unread_count)
      end

      sig { void }
      def read_all
        current_user!.notifications.unread.update_all(read_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        render json: { unread_count: 0 }
      end

      private

      sig { returns(Integer) }
      def unread_count = current_user!.notifications.unread.count
    end
  end
end
