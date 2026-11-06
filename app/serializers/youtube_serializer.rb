# typed: strict
# frozen_string_literal: true

# The shapes Settings › YouTube and a channel's tracking panel read.
module YoutubeSerializer
  extend T::Sig

  sig { params(preview: Youtube::Resolver::Preview).returns(T::Hash[Symbol, T.untyped]) }
  def self.preview(preview)
    channel = preview.channel
    {
      kind: preview.kind.serialize, url: preview.url, title: preview.title,
      channel: channel && {
        youtube_id: channel.youtube_id, title: channel.title, handle: channel.handle, description: channel.description,
        avatar_url: channel.avatar_url, banner_url: channel.banner_url,
        tracked: Channel.exists?(youtube_id: channel.youtube_id, tracked: true)
      },
      videos: preview.videos.first(200)
    }
  end

  sig { params(channel: Channel).returns(T::Hash[Symbol, T.untyped]) }
  def self.tracking(channel)
    counts = channel.youtube_downloads.group(:state).count
    {
      tracked: channel.tracked, youtube_id: channel.youtube_id, backfill: channel.backfill_enum.serialize,
      backfill_count: channel.backfill_count, backfill_since: channel.backfill_since, keep_last: channel.keep_last,
      skip_shorts: channel.skip_shorts, skip_live: channel.skip_live, title_filter: channel.title_filter, max_height: channel.max_height,
      poll_every_hours: channel.poll_every_hours, last_polled_at: channel.last_polled_at, last_poll_error: channel.last_poll_error,
      downloads: YoutubeDownload::State.values.to_h { |state| [ state.serialize, counts.fetch(state.serialize, 0) ] }
    }
  end

  sig { params(row: YoutubeDownload).returns(T::Hash[Symbol, T.untyped]) }
  def self.download(row)
    {
      id: row.id, youtube_id: row.youtube_id, title: row.title, state: row.state_enum.serialize, kept: row.kept, reason: row.reason,
      last_error: row.last_error, attempts: row.attempts, bytes: row.bytes, created_at: row.created_at,
      started_at: row.started_at, finished_at: row.finished_at
    }
  end
end
