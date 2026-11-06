# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # A channels library's channels, and one channel's videos (PROPOSAL §5.4).
    class ChannelsController < BaseController
      finds :channel, from: -> { Viewing::Access.channels(Channel.all) }
      skip_before_action :set_channel, only: :index

      SORTS = T.let({
        "newest" => "upload_date DESC NULLS LAST, created_at DESC", "oldest" => "upload_date ASC NULLS LAST, created_at ASC",
        "title" => "sort_title ASC"
      }.freeze, T::Hash[String, String])

      sig { void }
      def index
        scope = Channel.where(id: Channels::Catalog.watchable_videos.select(:channel_id))
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        scope = scope.where("unaccent(title) ILIKE unaccent(?)", "%#{Channel.sanitize_sql_like(params[:q].to_s)}%") if params[:q].present?
        channels = scope.order(:sort_title).to_a
        counts = Channels::Catalog.counts(current_profile!, channels)
        images = ArtworkSerializer.index(channels)
        subscribed = ChannelSubscription.where(profile: current_profile!, channel_id: channels.map(&:id)).pluck(:channel_id).to_set
        render json: channels.map { |channel|
          CatalogSerializer.channel_card(channel, images, counts.fetch(channel.id, {})).merge(
            url: channel.url, youtube_id: channel.youtube_id, tracked: channel.tracked, subscribed: subscribed.include?(channel.id)
          )
        }
      end

      sig { void }
      def show
        images = ArtworkSerializer.index([ channel ])
        counts = Channels::Catalog.counts(current_profile!, [ channel ]).fetch(channel.id, {})
        scope = Channels::Catalog.watchable_videos(channel.videos)
        if bool_param(:unwatched)
          watched = WatchState.finished(current_profile!, "Video")
          scope = scope.where.not(id: watched.select(:playable_id))
        end
        videos = paginate(scope.order(Arel.sql(SORTS.fetch(params[:sort].to_s, SORTS.fetch("newest")))), default_per: 60)
          .includes(:channel).to_a
        render json: CatalogSerializer.channel_card(channel, images, counts).merge(
          description: channel.description, url: channel.url, youtube_id: channel.youtube_id,
          subscribed: ChannelSubscription.exists?(profile: current_profile!, channel: channel),
          library: { id: channel.library_id, name: channel.library&.name },
          videos: Channels::Catalog.cards(current_profile!, videos)
        )
      end

      # Marks every video of the channel watched (or, with watched=false,
      # unwatched) for this profile — only the ones that change.
      sig { void }
      def watched
        flag = bool_param(:watched, default: true)
        finished = WatchState.finished(current_profile!, "Video").select(:playable_id)
        scope = Channels::Catalog.watchable_videos(channel.videos)
        scope = flag ? scope.where.not(id: finished) : scope.where(id: finished)
        scope.find_each { |video| Playback::Progress.mark(current_profile!, video, watched: flag) }
        head :no_content
      end
    end
  end
end
