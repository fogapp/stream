# typed: strict
# frozen_string_literal: true

module Playback
  # How much converting is going on, by picture size (PROPOSAL §6.3): the
  # limit in Settings counts full-size conversions, and a smaller one costs
  # less — 720p is under half of 1080p — so when a full-size conversion
  # won't fit, a smaller one often still does, and Play works at 720p rather
  # than not at all.
  module Budget
    extend T::Sig

    # Tried in turn when the full size won't fit.
    SMALLER = T.let([ 720, 480 ].freeze, T::Array[Integer])

    # A conversion's share of one full-size slot: by pixels, so 720p is
    # 0.44 and 480p 0.2 (nothing counts for less); 4K on hardware counts as
    # one, since hardware is what's allowed to do it.
    sig { params(height: T.nilable(Integer)).returns(Float) }
    def self.weight(height)
      (((height || 1080).to_f / 1080)**2).clamp(0.2, 1.0)
    end

    # What's being converted for viewers right now, in full-size slots.
    sig { returns(Float) }
    def self.load
      PlaybackSession.unscoped.converting_now.pluck(Arel.sql("(decision->'video'->>'height')::int")).sum(0.0) { |height| weight(height) }
    end

    sig { returns(Float) }
    def self.room = Placement.capacity - load

    # The decision to go with: as made when it fits (or isn't a video
    # conversion), else the tallest smaller conversion that fits, saying
    # why among its reasons; nil when nothing fits.
    sig do
      params(decision: Decision, decide: T.proc.params(max_height: Integer).returns(Decision)).returns(T.nilable(Decision))
    end
    def self.fit(decision, &decide)
      return decision unless decision.method == PlaybackSession::Method::VideoTranscode

      available = room
      height = decision.video&.height
      return decision if weight(height) <= available + 0.001

      SMALLER.select { |smaller| height.nil? || smaller < height }.each do |smaller|
        next if weight(smaller) > available + 0.001

        smaller_decision = decide.call(smaller)
        next unless smaller_decision.method == PlaybackSession::Method::VideoTranscode

        smaller_decision.reasons << "Smaller than it could be: the server is already converting as much as it can at full size"
        return smaller_decision
      end
      nil
    end
  end
end
