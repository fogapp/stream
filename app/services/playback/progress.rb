# typed: strict
# frozen_string_literal: true

module Playback
  # Where a viewer is, recorded on the session and folded into the
  # profile's watch state (PROPOSAL §4.4): resume points, "watched" at 90%,
  # and no Continue watching card for a two-minute peek.
  module Progress
    extend T::Sig

    # nil for a live stream (PROPOSAL §7.8): there's nothing to resume or to
    # have watched, only a session to keep open.
    sig { params(session: PlaybackSession, position: Float, ended: T::Boolean).returns(T.nilable(WatchState)) }
    def self.report(session, position:, ended: false)
      played(session, position)
      duration = session.media_file&.duration_seconds
      position = position.clamp(0.0, duration || Float::INFINITY)
      now = Time.current
      session.update!(position_seconds: position, last_seen_at: now)
      session.end! if ended
      return nil if session.playable_type == "LiveStream"
      return fold_live(session, duration: duration, position: position, now: now) if session.airing_id

      fold(profile_id: session.profile_id, playable: session.playable, media_file_id: session.media_file_id, duration: duration,
        position: position, began_at: session.started_at, now: now)
    end

    # A rung that has played this far works on this kind of client:
    # recorded once a session.
    sig { params(session: PlaybackSession, position: Float).void }
    def self.played(session, position)
      from = session.start_position_seconds
      return if session.outcome_recorded_at || from.nil? || session.failure_class || position - from < Learned::PLAYED

      session.update_columns(outcome_recorded_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      Learned.played!(session)
    end
    private_class_method :played

    # Watched on a Grid channel (PROPOSAL §7.7): it counts as watched
    # once seen to the end, having seen at least half of it — but it isn't
    # Continue watching or Next up, which are for what was chosen to watch,
    # so last_watched_at (what those read) is left where it was.
    sig do
      params(session: PlaybackSession, duration: T.nilable(Float), position: Float, now: ActiveSupport::TimeWithZone).returns(WatchState)
    end
    def self.fold_live(session, duration:, position:, now:)
      state = WatchState.find_or_initialize_by(profile_id: session.profile_id, playable: session.playable)
      # Between programs isn't watching anything.
      return state if session.airing&.filler

      length = duration.to_f
      # A program in parts is one viewing: joined where the earliest part
      # this profile watched was joined.
      joined = session.joined_at_seconds.to_f
      parts = session.airing&.parts || []
      if parts.size > 1
        earlier = PlaybackSession.where(profile_id: session.profile_id, airing_id: parts.map(&:id)).minimum(:joined_at_seconds)
        joined = [ joined, earlier.to_f ].min if earlier
      end
      seen = position - joined
      return state unless length.positive? && position >= length * WatchState::COMPLETE_AT && seen >= length * LIVE_SEEN

      completed = state.completed_at
      counted = !(completed && completed >= session.started_at)
      state.play_count += 1 if counted
      state.assign_attributes(completed_at: now, position_seconds: 0.0, media_file_id: session.media_file_id, duration_seconds: duration)
      state.save!
      Trakt::Outbox.watched(session.profile_id, session.playable, watched: true, at: now) if counted
      state
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    # How much of a program someone has to have seen live for it to count.
    LIVE_SEEN = 0.5

    # Watched offline, reported once the device is back online: the same
    # folding, as of when it was watched.
    sig { params(download: OfflineDownload, position: Float, watched_at: ActiveSupport::TimeWithZone).returns(WatchState) }
    def self.report_offline(download, position:, watched_at:)
      duration = download.media_file&.duration_seconds
      plays = WatchState.find_by(profile_id: download.profile_id, playable: download.playable)&.play_count.to_i
      state = fold(profile_id: download.profile_id, playable: download.playable, media_file_id: download.media_file_id, duration: duration,
        position: position.clamp(0.0, duration || Float::INFINITY), began_at: download.last_synced_at || download.created_at,
        now: watched_at)
      # Offline, nothing was scrobbled: the play goes to Trakt's history.
      Trakt::Outbox.watched(download.profile_id, download.playable, watched: true, at: watched_at) if state.play_count > plays
      state
    end

    # One report folded into the profile's watch state. began_at is when
    # this viewing started: reports keep arriving through the credits, and
    # one viewing is one play.
    sig do
      params(profile_id: String, playable: T.untyped, media_file_id: T.nilable(String), duration: T.nilable(Float), position: Float,
        began_at: ActiveSupport::TimeWithZone, now: ActiveSupport::TimeWithZone).returns(WatchState)
    end
    def self.fold(profile_id:, playable:, media_file_id:, duration:, position:, began_at:, now:)
      state = WatchState.find_or_initialize_by(profile_id: profile_id, playable: playable)
      finished = duration.to_f.positive? && position >= duration.to_f * WatchState::COMPLETE_AT
      began = position >= WatchState::STARTED_AFTER

      state.assign_attributes(media_file_id: media_file_id, duration_seconds: duration, last_watched_at: now,
        hidden_from_continue: false)
      if finished
        completed = state.completed_at
        state.play_count += 1 unless completed && completed >= began_at
        state.completed_at = now
        state.position_seconds = 0.0
        # Watched is done with: it leaves Watch later, as on YouTube.
        PlaylistItem.joins(:playlist).where(playlists: { profile_id: profile_id, system_kind: Playlist::WATCH_LATER },
          item_type: playable.class.name, item_id: playable.id).delete_all
      elsif began
        state.position_seconds = position
        # Rewatching something finished: it's in progress again.
        state.completed_at = nil
      end
      state.save!
      state
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    sig { params(profile: Profile, playable: T.any(Movie, Episode, Video, Clip), watched: T::Boolean).returns(WatchState) }
    def self.mark(profile, playable, watched:)
      state = WatchState.find_or_initialize_by(profile: profile, playable: playable)
      changed = watched ? !state.completed? : state.completed? || state.play_count.positive?
      if watched
        state.play_count += 1 unless state.completed?
        state.assign_attributes(completed_at: Time.current, position_seconds: 0, last_watched_at: Time.current, hidden_from_continue: false)
      else
        state.assign_attributes(completed_at: nil, position_seconds: 0, play_count: 0)
      end
      state.save!
      Trakt::Outbox.watched(profile.id, playable, watched: watched) if changed
      state
    end
  end
end
