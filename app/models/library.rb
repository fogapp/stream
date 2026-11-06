# typed: strict
# frozen_string_literal: true

# A set of root folders holding one shape of video (PROPOSAL §4.1). Roots are
# absolute paths inside the container — fog mounts Content/Movies at
# /media/movies and so on, but which folder is which library is decided here,
# never assumed from mount names.
class Library < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Movies = new("movies")
      Shows = new("shows")
      # YouTube channels (and any folder-per-maker video): Channel → Video.
      Channels = new("channels")
      # Home videos, placed in time (and, with Immich, in albums): Clip.
      HomeVideos = new("home_videos")
      # Cameras and web streams an admin added by URL (PROPOSAL §7.8): no
      # folders, nothing to scan — LiveStream.
      Live = new("live")
    end

    # Read from folders, and so scanned.
    sig { returns(T::Boolean) }
    def folders? = self != Live
  end

  MAX_ROOTS = 10

  # In one statement, however many: what was made from them is swept up
  # after (Media::DerivedFiles), not destroyed a row at a time.
  has_many :media_files, dependent: :delete_all
  has_many :movies, dependent: :destroy
  has_many :shows, dependent: :destroy
  has_many :channels, dependent: :destroy
  has_many :clips, dependent: :destroy
  has_many :live_streams, dependent: :destroy
  has_many :folder_listings, dependent: :delete_all

  attribute :kind, Kind

  after_destroy_commit { SweepDerivedFilesJob.perform_later }

  normalizes :name, with: ->(name) { name.strip }
  normalizes :roots, with: ->(roots) { Array(roots).map { |root| root.to_s.strip.chomp("/") }.compact_blank.uniq }

  validates :name, presence: true, length: { maximum: 80 }, uniqueness: { scope: :household_id }
  validates :metadata_language, format: { with: /\A[a-z]{2}(-[A-Z]{2})?\z/, message: "must look like en or en-GB" }
  validate :roots_are_usable

  # Where a scan last got to, for the Libraries screen.
  sig { returns(T::Boolean) }
  def scanning?
    started = last_scan_started_at
    return false if started.nil?

    finished = last_scanned_at
    finished.nil? || finished < started
  end

  # The root a path lives under, or nil when it lives under none — the check
  # every targeted scan and every served byte goes through (PROPOSAL §10).
  sig { params(path: String).returns(T.nilable(String)) }
  def root_for(path)
    real = Media::SafePath.real(path)
    return nil if real.nil?

    roots.find { |root| Media::SafePath.within?(real, root) }
  end

  private

  sig { void }
  def roots_are_usable
    if kind == Kind::Live.serialize
      errors.add(:roots, "aren't used by a live library") if roots.any?
      return
    end
    if roots.empty?
      errors.add(:roots, "need at least one folder")
      return
    end
    errors.add(:roots, "can have at most #{MAX_ROOTS} folders") if roots.size > MAX_ROOTS
    return unless will_save_change_to_roots?

    roots.each do |root|
      report = StorageLocation.inspect_path(root, writable: false)
      errors.add(:base, "#{root}: #{report.message}") unless report.ok
    end
    roots.each_with_index do |outer, i|
      roots.drop(i + 1).each do |inner|
        next unless Media::SafePath.within?(outer, inner) || Media::SafePath.within?(inner, outer)

        errors.add(:roots, "can't contain one another (#{outer} and #{inner})")
      end
    end
  end
end
