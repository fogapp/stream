# typed: strict
# frozen_string_literal: true

# Asks YouTube for an identified video's details (Youtube::Hydrator). Two at
# a time for the whole server, beside the downloads: a channel's worth of
# lookups at once is what YouTube throttles.
class HydrateVideoJob < ApplicationJob
  extend T::Sig

  queue_as :youtube
  limits_concurrency to: 2, key: ->(_video_id) { "youtube_details" }, duration: 10.minutes

  sig { params(video_id: String).void }
  def perform(video_id)
    video = Video.unscoped.find_by(id: video_id)
    return if video.nil?

    Youtube::Hydrator.new(video).call
  rescue Youtube::YtDlp::Error
    # Recorded on the file's YouTube details step, where Needs attention
    # lists it and Retry asks again; a members-only video says so there.
    nil
  end
end
