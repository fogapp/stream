# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Subscriptions (PROPOSAL §5.4): the watching profile's channels, and
    # its feed — their videos, newest first, the YouTube home people use.
    class SubscriptionsController < BaseController
      sig { void }
      def index
        channel_ids = current_profile!.channel_subscriptions.select(:channel_id)
        channels = Viewing::Access.channels(Channel.where(id: channel_ids)).order(:sort_title).to_a
        counts = Channels::Catalog.counts(current_profile!, channels)
        images = ArtworkSerializer.index(channels)
        videos = paginate(Channels::Catalog.watchable_videos(Video.where(channel_id: channel_ids))
          .order(Arel.sql("upload_date DESC NULLS LAST, created_at DESC")), default_per: 60).includes(:channel).to_a
        render json: {
          channels: channels.map { |channel| CatalogSerializer.channel_card(channel, images, counts.fetch(channel.id, {})) },
          videos: Channels::Catalog.cards(current_profile!, videos)
        }
      end

      sig { void }
      def create
        channel = Viewing::Access.channels(Channel.all).find(params.require(:channel_id))
        ChannelSubscription.find_or_create_by!(profile: current_profile!, channel: channel)
        render json: { subscribed: true }
      rescue ActiveRecord::RecordNotUnique
        render json: { subscribed: true }
      end

      sig { void }
      def destroy
        channel = Channel.find(params.require(:channel_id))
        ChannelSubscription.where(profile: current_profile!, channel: channel).delete_all
        render json: { subscribed: false }
      end
    end
  end
end
