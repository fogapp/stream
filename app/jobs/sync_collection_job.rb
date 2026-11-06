# typed: strict
# frozen_string_literal: true

# A TMDB collection's overview, pictures and film order (PROPOSAL §4.2).
class SyncCollectionJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(collection_id) { "collection:#{collection_id}" }
  retry_on UpstreamHttpClient::RateLimitError, wait: 1.minute, attempts: 5

  sig { params(collection_id: String).void }
  def perform(collection_id)
    collection = Collection.unscoped.find_by(id: collection_id)
    tmdb_id = collection&.tmdb_id
    return if collection.nil? || tmdb_id.nil?

    household = Household.find_by(id: collection.household_id)
    client = household && Tmdb::Client.for(household)
    return if client.nil?

    Catalog::Collections.apply(collection, client.collection(tmdb_id))
  rescue UpstreamHttpClient::RateLimitError
    raise
  rescue UpstreamHttpClient::Error => e
    Activity.record(source: "metadata", event: "collection.fetch_failed", severity: Activity::Severity::Warn,
      subject: collection, household_id: collection&.household_id, summary: "#{collection&.title}: #{e.message.truncate(200)}")
  end
end
