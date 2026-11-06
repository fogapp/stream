# typed: strict
# frozen_string_literal: true

# One image of a title, season, episode or person (PROPOSAL §4.2). Stream
# serves its own copies — rendered once, cached forever by URL version — so
# browsing never waits on TMDB and never breaks when TMDB does.
class Artwork < ApplicationRecord
  # Written, never read: dropped once no replica can still be writing it.
  self.ignored_columns += %w[rendered_at]

  extend T::Sig

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Poster = new("poster")
      Backdrop = new("backdrop")
      Logo = new("logo")
      Still = new("still")
      Profile = new("profile")
      # A frame from the file itself, for anything no provider pictured.
      Thumb = new("thumb")
    end

    extend T::Sig

    # Widths rendered for each kind: what the grids, rows and heroes ask
    # for at 1x and 2x.
    sig { returns(T::Array[Integer]) }
    def widths
      case self
      when Poster then [ 185, 342, 500 ]
      when Backdrop then [ 780, 1280, 1920 ]
      when Logo then [ 300, 500 ]
      when Still, Thumb then [ 300, 780 ]
      when Profile then [ 185 ]
      else T.absurd(self)
      end
    end

    # The TMDB size to download before rendering down from it.
    sig { returns(String) }
    def tmdb_size
      case self
      when Poster then "w780"
      when Backdrop then "original"
      when Logo then "w500"
      when Still then "w780"
      when Profile then "w185"
      when Thumb then "original"
      else T.absurd(self)
      end
    end
  end

  class Source < T::Enum
    include ApplicationEnum
    enums do
      Tmdb = new("tmdb")
      Frame = new("frame")
      # A custom poster or background carried over from Plex.
      Plex = new("plex")
      # An image beside the media: a video's thumbnail, a channel's avatar.
      Local = new("local")
      # A tracked channel's avatar or banner, from YouTube.
      Youtube = new("youtube")
      # A face Immich has named.
      Immich = new("immich")
      # Uploaded by an admin in Stream.
      Upload = new("upload")
    end
  end

  class State < T::Enum
    include ApplicationEnum
    enums do
      Pending = new("pending")
      Ready = new("ready")
      Failed = new("failed")
    end
  end

  belongs_to :owner, polymorphic: true

  attribute :kind, Kind
  attribute :source, Source
  attribute :state, State

  scope :ready, -> { where(state: State::Ready.serialize) }

  after_destroy_commit :remove_files

  sig { returns(Pathname) }
  def self.root
    Pathname.new(ENV.fetch("STREAM_STORAGE_DIR") { Rails.root.join("storage").to_s }).join("artwork")
  end

  sig { returns(Pathname) }
  def directory = self.class.root.join(id.to_s)

  sig { params(width: Integer).returns(Pathname) }
  def file_for(width) = directory.join(version.to_s, "#{width}.webp")

  sig { returns(T::Boolean) }
  def ready? = state_enum == State::Ready

  # Failures in a row before an image that keeps failing is left alone
  # until its source changes.
  GIVE_UP_AFTER = 5

  sig { returns(T::Boolean) }
  def given_up? = consecutive_failures >= GIVE_UP_AFTER

  # A render that failed: an earlier render still shows, the failure counts
  # toward giving up, and it's said where someone will see it — never
  # silently (CLAUDE.md, invariant 5).
  sig { params(error: StandardError).void }
  def record_failure!(error)
    update!(state: ready? ? State::Ready.serialize : State::Failed.serialize, last_error: error.message.truncate(300),
      consecutive_failures: consecutive_failures + 1)
    about = owner.try(:title) || owner.try(:name) || owner_type
    Activity.record(source: "artwork", event: "artwork.failed", severity: Activity::Severity::Warn,
      subject: self, summary: "#{kind} for #{about}: #{error.message.truncate(200)}")
  end

  private

  sig { void }
  def remove_files
    FileUtils.rm_rf(directory)
  end
end
