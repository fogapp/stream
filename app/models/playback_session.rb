# typed: strict
# frozen_string_literal: true

# One press of Play (PROPOSAL §4.4): which file, how it's being delivered
# and why, and where the viewer is. Its id is what a stream token signs.
class PlaybackSession < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  # Written and never read. Dropped by a later release: fog overlaps two
  # replicas in a swap, and the old one must already have stopped writing it.
  self.ignored_columns += %w[run_started_at]

  class Method < T::Enum
    include ApplicationEnum
    enums do
      Direct = new("direct")
      Remux = new("remux")
      AudioTranscode = new("audio_transcode")
      # The file's optimized version (OptimizedVersion), played as-is where
      # the original would need its video converted.
      Optimized = new("optimized")
      VideoTranscode = new("video_transcode")
    end

    # Delivered as HLS the transcoder produces, rather than a file served
    # as-is.
    sig { returns(T::Boolean) }
    def streamed? = self != Direct && self != Optimized

    # What the server is doing, in the admin pages' and messages' words.
    sig { returns(String) }
    def label
      case self
      when Direct then "Playing as-is"
      when Remux then "Repackaging"
      when AudioTranscode then "Converting the sound"
      when Optimized then "The optimized version"
      when VideoTranscode then "Converting the picture"
      else T.absurd(self)
      end
    end
  end

  class State < T::Enum
    include ApplicationEnum
    enums do
      Active = new("active")
      Ended = new("ended")
    end
  end

  # Where this play stands with Trakt's scrobbler (PROPOSAL §7.4); nil
  # before anything was sent, or when the profile isn't linked.
  class TraktScrobble < T::Enum
    include ApplicationEnum
    enums do
      Watching = new("watching")
      Paused = new("paused")
      # Stopped as watched: Trakt has the play.
      Done = new("done")
    end
  end

  # How a play went, worst first (the Playback page): a conversion that
  # failed, a player that reported an error, one that stalled, or none of
  # those. Derived from transcode_error and the session's events, never
  # stored.
  class Outcome < T::Enum
    include ApplicationEnum
    enums do
      Failed = new("failed")
      Errored = new("errored")
      Stalled = new("stalled")
      Clean = new("clean")
    end
  end

  # How a play failed, when it did and carried on as another session one
  # rung down the ladder.
  class FailureClass < T::Enum
    include ApplicationEnum
    enums do
      # The browser couldn't decode the picture or the sound: a decoder
      # error, audio over no picture. The same rung would fail again.
      Decode = new("decode")
      # It wouldn't open what it was given at all: the container, a codec
      # string, a stream it has no player for.
      Unsupported = new("unsupported")
      # It started but stopped getting anywhere: a stall that didn't end, or
      # nothing played at all in time.
      Stalled = new("stalled")
      # The network gave up on it after every retry.
      Network = new("network")
      # The transcoder gave up making it (transcode_error).
      Server = new("server")
    end

    extend T::Sig

    # A failure that isn't about this rung on this client but about the
    # evening: worth climbing back from (R2, "Upgrading back"), and never
    # learned from (R3).
    sig { returns(T::Boolean) }
    def transient? = self == Stalled || self == Network
  end

  # A session nobody has reported on in this long is over.
  IDLE_AFTER = T.let(30.minutes, ActiveSupport::Duration)

  belongs_to :profile
  belongs_to :user, optional: true
  belongs_to :playable, polymorphic: true
  # None for a live stream (PROPOSAL §7.8): its relay reads the address.
  belongs_to :media_file, optional: true
  belongs_to :device, optional: true
  # Converting on a remote transcoder rather than this machine's.
  belongs_to :transcode_node, optional: true
  # Started from a playlist: Up next is the playlist's next item.
  belongs_to :playlist, optional: true
  # Tuned in on a Grid channel: watched, but never Continue watching.
  belongs_to :airing, optional: true
  has_many :playback_events, dependent: :delete_all
  # The session this one carries on from, after it failed (R2).
  belongs_to :fallback_from, class_name: "PlaybackSession", optional: true
  has_one :fallback, class_name: "PlaybackSession", foreign_key: :fallback_from_id, inverse_of: :fallback_from, dependent: :nullify

  attribute :method, Method
  attribute :state, State
  attribute :trakt_scrobble, TraktScrobble, allow_nil: true
  attribute :failure_class, FailureClass, allow_nil: true

  # Sessions someone is actually watching: not a Grid channel tuned
  # ahead on standby (PROPOSAL §7.7).
  scope :watched, -> { where(standby: false) }

  # A conversion still running for a viewer: one that has reported lately.
  CONVERTING_WITHIN = T.let(2.minutes, ActiveSupport::Duration)
  scope :converting_now, -> {
    where(state: State::Active.serialize, method: Method::VideoTranscode.serialize).where(last_seen_at: CONVERTING_WITHIN.ago..)
  }

  sig { returns(T::Boolean) }
  def active? = state_enum == State::Active

  # The transcoder has given up on this play: what its waiting requests
  # answer with, and Activity.
  sig { params(message: String).void }
  def transcode_failed!(message)
    message = message.truncate(500)
    update_columns(transcode_error: message) # rubocop:disable Rails/SkipsModelValidations
    Activity.record(source: "playback", event: "transcode.failed", severity: Activity::Severity::Error,
      subject: self, household_id: household_id, summary: message)
  end

  # What the stored decision says, typed.
  sig { returns(Playback::StoredDecision) }
  def stored_decision = Playback::StoredDecision.new(decision)

  sig { returns(Playback::Constraints) }
  def constraints = stored_decision.constraints

  # The picture copied as it is, not converted.
  sig { returns(T::Boolean) }
  def video_copy? = stored_decision.copy?

  # The picture subtitle drawn into the video, by stream index.
  sig { returns(T.nilable(Integer)) }
  def burned_subtitle = stored_decision.burned_subtitle

  sig { void }
  def end!
    update!(state: State::Ended.serialize, ended_at: Time.current) if active?
  end

  # The sessions this play has been, oldest first: each fallback carries on
  # from the one before.
  sig { returns(T::Array[PlaybackSession]) }
  def chain
    sessions = [ self ]
    earlier = T.let(fallback_from, T.nilable(PlaybackSession))
    while earlier && sessions.size < 10
      sessions.unshift(earlier)
      earlier = earlier.fallback_from
    end
    sessions
  end
end
