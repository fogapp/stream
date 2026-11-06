# typed: strict
# frozen_string_literal: true

module Catalog
  # TMDB collections (PROPOSAL §4.2): a film that names one joins it, the
  # collection made the first time any of its films is read.
  module Collections
    extend T::Sig

    # Details are asked of TMDB again after this long.
    STALE_AFTER = T.let(30.days, ActiveSupport::Duration)

    sig { params(movie: Movie).void }
    def self.attach(movie)
      tmdb_id = movie.tmdb_collection_id
      stale = CollectionItem.joins(:collection).where(item: movie, collections: { kind: Collection::Kind::Tmdb.serialize })
      stale = stale.where.not(collections: { tmdb_id: tmdb_id }) if tmdb_id
      stale.delete_all
      return if tmdb_id.nil?

      collection = Collection.unscoped.find_or_create_by!(household_id: movie.household_id, tmdb_id: tmdb_id) do |row|
        row.kind = Collection::Kind::Tmdb.serialize
        row.title = movie.tmdb_collection_name.presence || "Collection"
        row.library_id = movie.library_id
      end
      CollectionItem.find_or_create_by!(collection: collection, item: movie)
      # Its films in more than one library: it's the household's.
      if collection.library_id && collection.library_id != movie.library_id && !collection.locked_fields.include?("library_id")
        collection.update!(library_id: nil)
      end
      refreshed = collection.metadata_refreshed_at
      SyncCollectionJob.perform_later(collection.id) if refreshed.nil? || refreshed < STALE_AFTER.ago
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    # Overview, pictures and the whole series from TMDB. (Its films show in
    # release order.)
    sig { params(collection: Collection, details: T::Hash[String, T.untyped]).void }
    def self.apply(collection, details)
      collection.assign_unlocked(title: details["name"].presence || collection.title, overview: details["overview"].presence,
        poster_path: details["poster_path"], backdrop_path: details["backdrop_path"])
      collection.metadata_refreshed_at = Time.current
      collection.save!
      parts = apply_parts(collection, Array(details["parts"]))
      ActiveJob.perform_all_later(
        [ SyncArtworkJob.new("Collection", collection.id) ] +
          parts.select { |part| part.poster_path.present? }.map { |part| SyncArtworkJob.new("CollectionPart", part.id) }
      )
    end

    # Every film TMDB lists, in release order; one it no longer lists goes,
    # with its poster.
    sig { params(collection: Collection, listed: T::Array[T.untyped]).returns(T::Array[CollectionPart]) }
    def self.apply_parts(collection, listed)
      listed = listed.select { |part| part.is_a?(Hash) && part["id"].is_a?(Integer) && part["title"].to_s.present? }
      listed = listed.sort_by { |part| [ release_date(part) || Date.new(9999), part["title"].to_s ] }
      parts = listed.each_with_index.map do |part, index|
        row = CollectionPart.unscoped.find_or_initialize_by(collection_id: collection.id, tmdb_id: part["id"])
        row.update!(household_id: collection.household_id, title: part["title"], release_date: release_date(part),
          overview: part["overview"].presence, poster_path: part["poster_path"].presence, position: index)
        row
      end
      gone = CollectionPart.unscoped.where(collection_id: collection.id).where.not(id: parts.map(&:id))
      Artwork.where(owner_type: "CollectionPart", owner_id: gone.select(:id)).destroy_all
      gone.delete_all
      parts
    end

    sig { params(part: T::Hash[String, T.untyped]).returns(T.nilable(Date)) }
    def self.release_date(part)
      Date.iso8601(part["release_date"].to_s)
    rescue Date::Error
      nil
    end
    private_class_method :apply_parts, :release_date
  end
end
