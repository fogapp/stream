# typed: strict
# frozen_string_literal: true

# A shelf of titles (PROPOSAL §4.2): TMDB's, gathered from the films that
# belong to it, or the household's own. A person's edits to a TMDB one are
# locked like any title's.
class Collection < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include LockedFields
  include SortTitled

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Tmdb = new("tmdb")
      Manual = new("manual")
      # Rules, worked out when looked at (Viewing::SmartCollection).
      Smart = new("smart")
    end
  end

  # One library's, or (nil) the household's.
  belongs_to :library, optional: true
  has_many :collection_items, -> { order(:position, :created_at) }, dependent: :delete_all, inverse_of: :collection
  # A TMDB collection's whole series, had or not.
  has_many :parts, -> { order(:position) }, class_name: "CollectionPart", dependent: :delete_all, inverse_of: :collection

  attribute :kind, Kind

  validates :title, presence: true, length: { maximum: 200 }

  sig { returns(T::Boolean) }
  def manual? = kind_enum == Kind::Manual

  sig { returns(T::Boolean) }
  def smart? = kind_enum == Kind::Smart

  # Movies and shows in order, skipping any that have since gone.
  sig { returns(T::Array[T.any(Movie, Show)]) }
  def items = T.must(Collection.items_for([ self ])[id])

  # Many collections' items at once: the listed titles are loaded together,
  # not collection by collection. A smart one still works out its own.
  sig { params(collections: T::Array[Collection]).returns(T::Hash[T.nilable(String), T::Array[T.any(Movie, Show)]]) }
  def self.items_for(collections)
    rows = collections.reject(&:smart?).flat_map { |collection| collection.collection_items.to_a }
    movies = Movie.where(id: rows.select { |row| row.item_type == "Movie" }.map(&:item_id).uniq).index_by(&:id)
    shows = Show.where(id: rows.select { |row| row.item_type == "Show" }.map(&:item_id).uniq).index_by(&:id)
    collections.to_h do |collection|
      [ collection.id, collection.smart? ? Viewing::SmartCollection.items(collection.rules) : collection.listed(movies, shows) ]
    end
  end

  # This collection's rows as titles, from the ones already loaded.
  sig { params(movies: T::Hash[String, Movie], shows: T::Hash[String, Show]).returns(T::Array[T.any(Movie, Show)]) }
  def listed(movies, shows)
    items = collection_items.to_a.filter_map { |row| row.item_type == "Movie" ? movies[row.item_id] : shows[row.item_id] }
    return items if manual?

    # TMDB's are a series: in the order they came out.
    items.sort_by { |item| [ item.try(:release_date) || Date.new(item.year || 9999), item.title ] }
  end
end
