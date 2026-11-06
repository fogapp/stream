# typed: strict
# frozen_string_literal: true

# One video file under a library root, identified by content (PROPOSAL §4.1).
# Its fingerprint survives renames and moves: a file that vanishes is marked
# missing, and if the same fingerprint appears elsewhere the row moves with
# everything hung off it (CLAUDE.md invariant 2).
class MediaFile < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class State < T::Enum
    include ApplicationEnum
    enums do
      # Seen on disk; not yet probed.
      Discovered = new("discovered")
      # Probed and fingerprinted; streams known. Browsable.
      Probed = new("probed")
      # ffprobe couldn't read it: truncated, not video, or unreadable.
      Broken = new("broken")
      # Gone from disk; kept for MISSING_GRACE in case it reappears.
      Missing = new("missing")
    end
  end

  # How long a vanished file waits for its fingerprint to reappear before
  # it is deleted. Watch state outlives it: the state keeps the title, and
  # only its link to this file is cleared.
  MISSING_GRACE = T.let(30.days, ActiveSupport::Duration)

  VIDEO_EXTENSIONS = T.let(%w[
    .mkv .mp4 .m4v .mov .avi .ts .m2ts .mts .webm .wmv .mpg .mpeg .flv .ogv .3gp
  ].to_set.freeze, T::Set[String])

  belongs_to :library
  has_many :media_streams, -> { order(:index) }, dependent: :delete_all, inverse_of: :media_file
  has_many :analysis_runs, dependent: :delete_all
  has_many :editions, dependent: :delete_all
  has_one :extra, dependent: :delete
  has_one :transcript, dependent: :destroy
  has_one :trickplay, dependent: :destroy
  has_one :optimized_version, dependent: :destroy
  has_many :markers, dependent: :delete_all
  has_many :audio_fingerprints, dependent: :delete_all

  # Its extracted subtitles and thumbnails (the rows above take theirs).
  after_destroy_commit { Media::DerivedFiles.remove(T.bind(self, MediaFile).id) }

  attribute :state, State

  validates :path, presence: true, uniqueness: { scope: :household_id }
  validates :size, numericality: { greater_than_or_equal_to: 0 }

  scope :present, -> { where.not(state: State::Missing.serialize) }
  scope :playable, -> { where(state: State::Probed.serialize) }

  sig { params(path: String).returns(T::Boolean) }
  def self.video_path?(path)
    VIDEO_EXTENSIONS.include?(File.extname(path).downcase)
  end

  sig { returns(String) }
  def filename = File.basename(path)

  # The original, when it may be served: resolved and checked against its
  # library's roots on every call, so a symlink swapped in after the scan
  # still can't reach outside (PROPOSAL §10). nil when it can't be.
  sig { returns(T.nilable(Pathname)) }
  def servable_path
    library = self.library
    return nil if library.nil? || library.root_for(path.to_s).nil? || !File.file?(path.to_s)

    Pathname.new(path.to_s)
  end

  sig { returns(T.nilable(MediaStream)) }
  def primary_video
    media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Video }
  end
end
