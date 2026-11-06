# typed: strict
# frozen_string_literal: true

# One scrobble to Trakt (PROPOSAL §7.4): start, pause or stop, as
# Trakt::Scrobbler decided. A stop Trakt never took goes to its history
# instead, so the play isn't lost.
class TraktScrobbleJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(session_id, *_rest) { "trakt_scrobble:#{session_id}" }, duration: 5.minutes

  retry_on UpstreamHttpClient::Error, wait: 20.seconds, attempts: 4 do |job, _error|
    job.fall_back
  end

  sig { params(session_id: String, action: String, progress: Float).void }
  def perform(session_id, action, progress)
    session = PlaybackSession.unscoped.find_by(id: session_id)
    account = TraktAccount.linked_for(session&.profile_id)
    item = session && (session.playable.is_a?(Movie) || session.playable.is_a?(Episode)) ? Trakt::Items.scrobble_item(session.playable) : nil
    return if account.nil? || item.nil?

    Trakt::Api.for(account).post("/scrobble/#{Trakt::Scrobbler::Action.deserialize(action).serialize}",
      item.merge(progress: progress, app_version: StreamVersion.short_sha))
  rescue Trakt::Client::Error => e
    # Trakt already has this play (a stop repeated within its runtime).
    raise unless e.status == 409
  rescue Trakt::Api::Unlinked
    nil
  end

  # Out of retries: a stop becomes a history entry the outbox keeps trying.
  sig { void }
  def fall_back
    session_id, action, = arguments
    return unless action == Trakt::Scrobbler::Action::Stop.serialize

    session = PlaybackSession.unscoped.find_by(id: session_id)
    return if session.nil?

    Trakt::Outbox.watched(session.profile_id, session.playable, watched: true, at: session.trakt_scrobbled_at || Time.current)
  end
end
