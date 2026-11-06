# typed: strict
# frozen_string_literal: true

module Trakt
  # Live scrobbling (PROPOSAL §7.4). The players only report where they are,
  # every ten seconds while playing and once at the end, so Stream works the
  # rest out: the first report starts a scrobble, a play Stream counts as
  # watched stops it (Trakt records the play), an early end pauses it (Trakt
  # keeps the resume point), and reports that stop coming — paused, or the
  # tab gone — are paused by TraktScrobbleSweepJob. Each move is claimed on
  # the session row first, so overlapping reports send it once.
  module Scrobbler
    extend T::Sig

    Scrobble = PlaybackSession::TraktScrobble

    class Action < T::Enum
      enums do
        Start = new("start")
        Pause = new("pause")
        Stop = new("stop")
      end

      sig { returns(Scrobble) }
      def lands_on
        case self
        when Start then Scrobble::Watching
        when Pause then Scrobble::Paused
        when Stop then Scrobble::Done
        else T.absurd(self)
        end
      end
    end

    # Reports this long apart mean the player has gone quiet.
    QUIET_AFTER = T.let(45.seconds, ActiveSupport::Duration)

    sig { params(session: PlaybackSession, state: WatchState, ended: T::Boolean).void }
    def self.observe(session, state, ended:)
      return unless scrobbles?(session)

      completed = state.completed_at
      current = session.trakt_scrobble_enum
      action = if completed && completed >= session.started_at
        Action::Stop unless current == Scrobble::Done
      elsif ended
        Action::Pause if current == Scrobble::Watching
      elsif current != Scrobble::Watching
        Action::Start
      end
      send_scrobble(session, action, from: current) if action
    end

    # Plays whose reports stopped: paused on Trakt.
    sig { returns(Integer) }
    def self.sweep
      PlaybackSession.unscoped.where(trakt_scrobble: Scrobble::Watching.serialize).where(last_seen_at: ...QUIET_AFTER.ago)
        .count { |session| send_scrobble(session, Action::Pause, from: Scrobble::Watching) }
    end

    sig { params(session: PlaybackSession).returns(T::Boolean) }
    def self.scrobbles?(session)
      # Grid and a channel tuned ahead aren't chosen plays; a Grid play
      # reaches Trakt's history when it counts as watched.
      return false if session.airing_id || session.standby
      return false unless session.playable.is_a?(Movie) || session.playable.is_a?(Episode)
      return false unless session.media_file&.duration_seconds.to_f.positive?

      !TraktAccount.linked_for(session.profile_id).nil?
    end

    sig { params(session: PlaybackSession, action: Action, from: T.nilable(Scrobble)).returns(T::Boolean) }
    def self.send_scrobble(session, action, from:)
      claimed = PlaybackSession.unscoped.where(id: session.id, trakt_scrobble: from&.serialize)
        .update_all(trakt_scrobble: action.lands_on.serialize, trakt_scrobbled_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      return false unless claimed == 1

      duration = session.media_file&.duration_seconds.to_f
      progress = duration.positive? ? (session.position_seconds.to_f / duration * 100).clamp(0.0, 100.0).round(2) : 0.0
      TraktScrobbleJob.perform_later(session.id, action.serialize, progress)
      true
    end
    private_class_method :send_scrobble
  end
end
