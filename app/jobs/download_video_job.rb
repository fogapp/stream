# typed: strict
# frozen_string_literal: true

# Fetches one video from YouTube (PROPOSAL §5.4). Two at a time, for the
# whole server: YouTube throttles a busy address, and the NAS is shared.
# Its own queue, so a download never waits behind a library's ffmpeg work.
class DownloadVideoJob < ApplicationJob
  extend T::Sig

  queue_as :youtube
  limits_concurrency to: 2, key: ->(_download_id) { "youtube_download" }, duration: 4.hours

  RETRY_AFTER = T.let(30.minutes, ActiveSupport::Duration)

  sig { params(download_id: String).void }
  def perform(download_id)
    download = YoutubeDownload.unscoped.find_by(id: download_id)
    return if download.nil?
    return unless [ YoutubeDownload::State::Queued, YoutubeDownload::State::Downloading ].include?(download.state_enum)

    Youtube::Downloader.new(download).call
  rescue Youtube::YtDlp::Error, Youtube::Tracker::NoDownloadFolder, SystemCallError => e
    failed(T.must(download), e)
  end

  private

  sig { params(download: YoutubeDownload, error: StandardError).void }
  def failed(download, error)
    if download.attempts < YoutubeDownload::MAX_ATTEMPTS
      download.update!(state: YoutubeDownload::State::Queued.serialize, last_error: error.message.truncate(300))
      self.class.set(wait: RETRY_AFTER * download.attempts).perform_later(download.id)
      return
    end

    download.update!(state: YoutubeDownload::State::Failed.serialize, last_error: error.message.truncate(300), finished_at: Time.current)
    Activity.record(source: "youtube", event: "download.failed", severity: Activity::Severity::Warn, subject: download.channel,
      household_id: download.household_id,
      summary: "Couldn't download #{download.title.presence || download.youtube_id} after #{download.attempts} tries: #{error.message.truncate(200)}")
  end
end
