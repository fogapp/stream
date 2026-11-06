# typed: strict
# frozen_string_literal: true

module Playback
  # Media URLs carry a stream token instead of a bearer header (PROPOSAL
  # §3.3): a <video> element — Safari's native HLS above all — can't send
  # one. The token signs one playback session and an expiry. Ending the
  # session revokes it; rotating STREAM_TOKEN_KEY revokes them all without
  # signing anyone out.
  module StreamToken
    extend T::Sig

    LIFETIME = T.let(6.hours, ActiveSupport::Duration)

    sig { params(session: PlaybackSession, now: T.any(Time, ActiveSupport::TimeWithZone)).returns(String) }
    def self.issue(session, now: Time.current) = SignedToken.issue("", session.id.to_s, (now + LIFETIME).to_i.to_s)

    # The active session a token names, or nil for anything forged, expired
    # or ended.
    sig { params(token: String, now: T.any(Time, ActiveSupport::TimeWithZone)).returns(T.nilable(PlaybackSession)) }
    def self.verify(token, now: Time.current)
      id, expires = SignedToken.fields("", token, count: 2)
      return nil if id.nil? || expires.to_i < now.to_i

      session = PlaybackSession.unscoped.find_by(id: id)
      session&.active? ? session : nil
    end
  end
end
