# typed: strict
# frozen_string_literal: true

# Keeps yt-dlp current (PROPOSAL §5.4): YouTube changes under it every few
# weeks, and an old copy stops finding formats.
class UpdateYtDlpJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: -> { "yt_dlp_update" }

  sig { void }
  def perform
    before = Youtube::YtDlp.version
    after = Youtube::YtDlp.update!
    return if before == after

    Activity.record(source: "youtube", event: "yt_dlp.updated", summary: "yt-dlp updated#{before ? " from #{before}" : ''} to #{after}")
    # YouTube pulls behave differently after this: a marker on every chart.
    Lucid.event("yt-dlp updated", tags: { version: after.to_s })
  rescue Youtube::YtDlp::Error, ToolRunner::Error, UpstreamHttpClient::Error, SystemCallError => e
    Activity.record(source: "youtube", event: "yt_dlp.update_failed", severity: Activity::Severity::Warn,
      summary: "Couldn't update yt-dlp: #{e.message.truncate(200)}")
  end
end
