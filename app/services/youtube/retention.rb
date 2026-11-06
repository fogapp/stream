# typed: strict
# frozen_string_literal: true

module Youtube
  # A channel's keep-last rule (PROPOSAL §5.4): Stream's own downloads
  # beyond the newest N are deleted — never a file Stream didn't fetch,
  # never one someone marked to keep, never one someone is partway through,
  # never outside the download folder. A kept download doesn't count
  # towards the N: the channel keeps its newest N besides.
  class Retention
    extend T::Sig

    sig { params(channel: Channel).void }
    def initialize(channel)
      @channel = channel
    end

    sig { void }
    def call
      keep = @channel.keep_last
      root = @channel.library&.download_root
      return if keep.nil? || root.nil?

      done = @channel.youtube_downloads.where(state: YoutubeDownload::State::Done.serialize, kept: false).to_a
      dates = Video.unscoped.where(channel_id: @channel.id, youtube_id: done.map(&:youtube_id)).pluck(:youtube_id, :upload_date).to_h
      ordered = done.sort_by { |row| [ dates[row.youtube_id] || Date.new(1970), row.created_at ] }.reverse
      removed = ordered.drop(keep).count { |row| remove(row, root) }
      ScanLibraryJob.perform_later(@channel.library_id, File.join(root, @channel.folder)) if removed.positive?
    end

    private

    sig { params(row: YoutubeDownload, root: String).returns(T::Boolean) }
    def remove(row, root)
      path = row.path
      return false if path.nil? || !Media::SafePath.within?(path, root) || being_watched?(row)

      DownloadFiles.delete(path)
      row.update!(state: YoutubeDownload::State::Removed.serialize, finished_at: Time.current)
      true
    end

    sig { params(row: YoutubeDownload).returns(T::Boolean) }
    def being_watched?(row)
      video = Video.unscoped.find_by(channel_id: @channel.id, youtube_id: row.youtube_id)
      return false if video.nil?

      WatchState.in_progress.exists?(playable: video)
    end
  end
end
