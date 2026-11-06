# typed: strict
# frozen_string_literal: true

# Asks TMDB which trailer one title has (Trailers.remember). One at a time,
# to go easy on TMDB; queued by the daily pass (FetchTrailersJob).
class CheckTrailerJob < ApplicationJob
  extend T::Sig

  # One line on the timeline for a whole pass of refusals.
  FAILURE_NOTED_FOR = T.let(20.hours, ActiveSupport::Duration)
  KINDS = T.let({ "Movie" => [ Movie, "movie" ], "Show" => [ Show, "show" ] }.freeze, T::Hash[String, [ T.untyped, String ]])

  queue_as :sync
  limits_concurrency to: 1, key: "trailer_check", duration: 10.minutes
  retry_on UpstreamHttpClient::RateLimitError, wait: 1.minute, attempts: 5

  sig { params(type: String, id: String).void }
  def perform(type, id)
    model, kind = KINDS.fetch(type)
    title = model.unscoped.find_by(id: id)
    household = title && Household.find_by(id: title.household_id)
    client = Tmdb::Client.for(household) if household
    tmdb_id = title&.tmdb_id
    return if client.nil? || tmdb_id.nil?

    Trailers.remember(title, client.videos(kind, tmdb_id.to_i))
  rescue UpstreamHttpClient::RateLimitError
    raise
  rescue UpstreamHttpClient::Error => e
    # Not stamped, so it's first in line tomorrow.
    note_failure(title&.household_id, e)
  end

  private

  sig { params(household_id: T.nilable(String), error: UpstreamHttpClient::Error).void }
  def note_failure(household_id, error)
    return unless Rails.cache.write("stream/trailers/check-failed/#{household_id}", true, unless_exist: true, expires_in: FAILURE_NOTED_FOR)

    Activity.record(source: "metadata", event: "trailers.check_failed", severity: Activity::Severity::Warn, household_id: household_id,
      summary: "Couldn't ask TMDB for trailers: #{error.message.truncate(200)}")
  end
end
