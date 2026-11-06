# typed: strict
# frozen_string_literal: true

module Playback
  # Web asks the transcoder for a GOP over Postgres NOTIFY (PROPOSAL §3.2):
  # no queue in between, because a seek has to restart ffmpeg in well under
  # a second.
  module Signal
    extend T::Sig

    CHANNEL = "stream_transcode"

    # resent: a waiting request asking again (Segments::RESIGNAL_EVERY), in
    # case the first ask was lost; never grounds to move a run away from
    # where the viewer has since asked to be (Supervisor#request).
    sig { params(session_id: String, gop: Integer, variant: Integer, resent: T::Boolean).void }
    def self.request(session_id, gop, variant = 0, resent: false)
      connection = ActiveRecord::Base.connection
      body = { "session" => session_id, "gop" => gop, "variant" => variant }
      body["resent"] = true if resent
      payload = connection.quote(body.to_json)
      # NOTIFY rather than SELECT pg_notify(): the function returns void,
      # which the adapter warns it can't type on every call.
      connection.execute("NOTIFY #{CHANNEL}, #{payload}")
    end

    # A live stream's player wants its relay running (LiveRelays): sent on
    # every playlist fetch, and a no-op for one that already is.
    sig { params(session_id: String).void }
    def self.relay(session_id)
      connection = ActiveRecord::Base.connection
      connection.execute("NOTIFY #{CHANNEL}, #{connection.quote({ 'relay' => session_id }.to_json)}")
    end

    # The other way: a fragment of this session is ready (Readiness).
    sig { params(session_id: String, variant: Integer, gop: Integer).void }
    def self.ready(session_id, variant, gop)
      connection = ActiveRecord::Base.connection
      connection.execute("NOTIFY #{Readiness::CHANNEL}, #{connection.quote("#{session_id}:#{variant}:#{gop}")}")
    end
  end
end
