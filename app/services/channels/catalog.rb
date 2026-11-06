# typed: strict
# frozen_string_literal: true

module Channels
  # The queries the channel pages are built from (PROPOSAL §5.4).
  module Catalog
    extend T::Sig

    sig { params(scope: T.untyped).returns(T.untyped) }
    def self.watchable_videos(scope = Video.all)
      Viewing::Access.videos(scope.where(id: Viewing::Catalog.readable_ids("Video")))
    end

    # Per channel: videos that play, those this profile hasn't finished,
    # and the newest upload.
    sig { params(profile: Profile, channels: T::Array[Channel]).returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
    def self.counts(profile, channels)
      return {} if channels.empty?

      videos = watchable_videos(Video.where(channel_id: channels.map(&:id)))
      table = Video.arel_table
      unfinished = table[:id].not_in(WatchState.finished(profile, "Video").select(:playable_id).arel)
      rows = videos.group(:channel_id).pluck(:channel_id, Arel.star.count, Arel.star.count.filter(unfinished), table[:upload_date].maximum)
        .to_h { |id, total, unwatched, latest| [ id, { videos: total, unwatched: unwatched, latest: latest } ] }
      channels.to_h { |channel| [ channel.id, rows.fetch(channel.id) { { videos: 0, unwatched: 0, latest: nil } } ] }
    end

    # More from a video's channel, newest first: what this profile hasn't
    # finished, and only then what it has.
    sig { params(profile: Profile, video: Video, limit: Integer).returns(T::Array[Video]) }
    def self.more_from_channel(profile, video, limit:)
      newest = watchable_videos(Video.where(channel_id: video.channel_id)).where.not(id: video.id)
        .order(Arel.sql("upload_date DESC NULLS LAST, created_at DESC, id")).includes(:channel)
      watched = WatchState.finished(profile, "Video").select(:playable_id)
      unwatched = newest.where.not(id: watched).limit(limit).to_a
      return unwatched if unwatched.size == limit

      unwatched + newest.where(id: watched).limit(limit - unwatched.size).to_a
    end

    # Durations for a page of videos, from their (largest) file.
    sig { params(videos: T::Array[Video]).returns(T::Hash[String, Float]) }
    def self.durations(videos)
      return {} if videos.empty?

      Edition.readable.where(playable_type: "Video", playable_id: videos.map(&:id))
        .pluck(:playable_id, "media_files.duration_seconds").each_with_object({}) do |(id, duration), found|
          found[id] = duration.to_f if duration && duration.to_f > found.fetch(id, 0.0)
        end
    end

    # A page of video cards with progress, durations and channel avatars.
    sig { params(profile: Profile, videos: T::Array[Video]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.cards(profile, videos)
      cards = Viewing::Cards.new(profile).prime(videos)
      videos.map { |video| cards.card(video) }
    end

    # Chapters for the player and the watch page: the file's own, else
    # info.json's, else the description's timestamps.
    sig { params(video: Video, file: T.nilable(MediaFile)).returns(T::Array[T::Hash[String, T.untyped]]) }
    def self.chapters(video, file)
      from_file = file&.chapters || []
      return from_file if from_file.any?
      return video.chapters if video.chapters.any?

      Timestamps.chapters(video.description, file&.duration_seconds)
    end
  end
end
