# typed: strict
# frozen_string_literal: true

module Playback
  # The transcoder process saying it's alive (bin/transcoder, every tick),
  # so the Playback page can tell "waiting for quiet hours" from "nothing
  # is running to encode anything". A row per host (TranscoderBeat): two
  # overlap while a deploy swaps them.
  module TranscoderHeartbeat
    extend T::Sig

    # Quiet for this long, it's gone: a tick is every five seconds.
    ALIVE = T.let(1.minute, ActiveSupport::Duration)

    class Beat < T::Struct
      const :at, ActiveSupport::TimeWithZone
      const :encoder, String
      # Converting video for someone watching: optimizing gives way.
      const :busy, T::Boolean
    end

    sig { params(encoder: Encoders::Kind, busy: T::Boolean, host: String).void }
    def self.beat!(encoder:, busy:, host: Socket.gethostname)
      now = Time.current
      TranscoderBeat.upsert({ host: host, encoder: encoder.serialize, busy: busy, seen_at: now, created_at: now, updated_at: now },
        unique_by: :host)
    end

    sig { params(host: String).void }
    def self.stopped!(host: Socket.gethostname)
      TranscoderBeat.where(host: host).delete_all
    end

    # The latest beat while it's recent; nil when no transcoder is running.
    # Busy if any running transcoder is.
    sig { returns(T.nilable(Beat)) }
    def self.current
      beats = TranscoderBeat.where(seen_at: ALIVE.ago..).order(seen_at: :desc).to_a
      latest = beats.first
      return nil unless latest

      Beat.new(at: latest.seen_at, encoder: latest.encoder, busy: beats.any?(&:busy))
    end
  end
end
