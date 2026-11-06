# typed: strict
# frozen_string_literal: true

# TMDB collections get their details again (PROPOSAL §4.2): the ones that
# haven't listed their whole series yet, and every month after, so a new
# film in a series shows up faded before anyone has it. Fans out only.
class RefreshCollectionsJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: "refresh_collections"

  BATCH = 200

  sig { void }
  def perform
    tmdb = Collection.unscoped.where(kind: Collection::Kind::Tmdb.serialize).where.not(tmdb_id: nil)
    unlisted = tmdb.where.not(id: CollectionPart.unscoped.select(:collection_id))
    stale = tmdb.where("metadata_refreshed_at IS NULL OR metadata_refreshed_at < ?", Catalog::Collections::STALE_AFTER.ago)
    ids = unlisted.or(stale).order(:metadata_refreshed_at).limit(BATCH).pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| SyncCollectionJob.new(id) })
  end
end
