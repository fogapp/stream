# typed: strict
# frozen_string_literal: true

# Asks TMDB again for a matched title's details (PROPOSAL §5.2): after a
# person unlocks a field, or when asked to. Locked fields stay as they are.
class RefreshMetadataJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(type, id) { "metadata:#{type}:#{id}" }
  retry_on UpstreamHttpClient::RateLimitError, wait: 1.minute, attempts: 5

  sig { params(type: String, id: String).void }
  def perform(type, id)
    record = { "Movie" => Movie, "Show" => Show, "Episode" => Episode }[type]&.unscoped&.find_by(id: id)
    return if record.nil?

    household = Household.find_by(id: record.is_a?(Episode) ? record.show&.household_id : record.household_id)
    client = household && Tmdb::Client.for(household)
    return if client.nil?

    case record
    when Movie
      tmdb_id = record.tmdb_id
      Catalog::Metadata.apply_movie(record, client.movie(tmdb_id)) if tmdb_id
    when Show
      tmdb_id = record.tmdb_id
      Catalog::Metadata.apply_show(record, client.show(tmdb_id)) if tmdb_id
    when Episode
      show = record.show
      tmdb_id = show&.tmdb_id
      Catalog::Metadata.apply_season(show, client.season(tmdb_id, record.season_number)) if show && tmdb_id
    end
  rescue UpstreamHttpClient::RateLimitError
    raise
  rescue UpstreamHttpClient::Error => e
    Activity.record(source: "metadata", event: "metadata.refresh_failed", severity: Activity::Severity::Warn,
      household_id: household&.id, summary: "Couldn't refresh #{type.downcase} details: #{e.message.truncate(200)}")
  end
end
