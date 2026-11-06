# typed: strict
# frozen_string_literal: true

# A profile's list of movies and episodes, played in order (PROPOSAL §7.4).
class Playlist < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :profile
  has_many :playlist_items, -> { order(:position, :created_at) }, dependent: :delete_all, inverse_of: :playlist

  validates :title, presence: true, length: { maximum: 200 }

  WATCH_LATER = "watch_later"

  # Every profile's Watch later, made the first time it's wanted.
  sig { params(profile: Profile).returns(Playlist) }
  def self.watch_later_for(profile)
    unscoped.find_or_create_by!(profile_id: profile.id, system_kind: WATCH_LATER) do |playlist|
      playlist.household_id = profile.household_id
      playlist.title = "Watch later"
    end
  rescue ActiveRecord::RecordNotUnique
    unscoped.find_by!(profile_id: profile.id, system_kind: WATCH_LATER)
  end

  sig { returns(T::Boolean) }
  def watch_later? = system_kind == WATCH_LATER

  # Puts something at the end, once; Trakt hears of a Watch later save.
  sig { params(item: T.any(Movie, Episode, Video)).void }
  def add!(item)
    last = playlist_items.maximum(:position).to_i
    PlaylistItem.find_or_create_by!(playlist: self, item: item) { |row| row.position = last + 1 }
    Trakt::Outbox.watch_later(profile_id, item, saved: true) if watch_later?
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # Movies and episodes in order, skipping any that have since gone or
  # that the watching profile may not see (Viewing::Access).
  sig { returns(T::Array[T.any(Movie, Episode, Video)]) }
  def items = T.must(self.class.items_for([ self ])[id])

  # The same for several playlists at once, in a fixed number of queries
  # however many there are (the playlists page).
  sig { params(playlists: T::Array[Playlist]).returns(T::Hash[String, T::Array[T.any(Movie, Episode, Video)]]) }
  def self.items_for(playlists)
    rows = PlaylistItem.where(playlist_id: playlists.map(&:id)).order(:position, :created_at).to_a
    ids = ->(type) { rows.select { |row| row.item_type == type }.map(&:item_id) }
    found = {
      "Movie" => Movie.where(id: ids.call("Movie")).index_by(&:id),
      "Episode" => Episode.where(id: ids.call("Episode")).includes(:show).index_by(&:id),
      "Video" => Video.where(id: ids.call("Video")).includes(:channel).index_by(&:id)
    }
    visible = Viewing::Access.permitted(found.values.flat_map(&:values)).to_set
    by_playlist = rows.group_by(&:playlist_id)
    playlists.to_h do |playlist|
      [ playlist.id, by_playlist.fetch(playlist.id, []).filter_map { |row| found.fetch(row.item_type, {})[row.item_id] }.select { |item| visible.include?(item) } ]
    end
  end

  # What plays after this one: the next item that has a readable file.
  sig { params(current: T.untyped).returns(T.nilable(T.any(Movie, Episode, Video))) }
  def after(current)
    list = items
    index = list.index(current)
    return nil if index.nil?

    readable = Viewing::Catalog.readable_editions
    list.drop(index + 1).find { |item| readable.exists?(playable: item) }
  end
end
