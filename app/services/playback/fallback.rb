# typed: strict
# frozen_string_literal: true

module Playback
  # The ladder a play climbs down when it fails, the way Plex and Jellyfin clients retry a failed play another
  # way:
  #
  #   direct → remux → audio converted → video converted (hardware) → video converted (software)
  #
  # Each step adds a constraint (Constraints) to the session that failed, so
  # a second failure goes on from the first; the decision then picks the
  # cheapest rung that's left. A picture the browser couldn't decode goes
  # straight to converting it — repackaging the same picture won't help.
  module Fallback
    extend T::Sig

    # Rungs one play may try before it's given up on.
    LIMIT = 3

    # One rung down from a method played under these constraints. nil when
    # there's none: a picture converted in software that still failed.
    sig do
      params(method: PlaybackSession::Method, now: Constraints, failure: PlaybackSession::FailureClass, hardware: T::Boolean)
        .returns(T.nilable(Constraints))
    end
    def self.next_constraints_for(method, now, failure, hardware:)
      decode = failure == PlaybackSession::FailureClass::Decode
      case method
      when PlaybackSession::Method::Direct
        decode ? now.with(no_direct: true, convert_video: true) : now.with(no_direct: true)
      when PlaybackSession::Method::Optimized
        now.with(no_direct: true, no_optimized: true, convert_video: true)
      when PlaybackSession::Method::Remux, PlaybackSession::Method::AudioTranscode
        if decode then now.with(no_direct: true, convert_video: true)
        elsif !now.convert_audio then now.with(no_direct: true, convert_audio: true)
        else now.with(no_direct: true, convert_video: true)
        end
      when PlaybackSession::Method::VideoTranscode
        converted = now.with(no_direct: true, no_optimized: true, convert_video: true)
        if !now.convert_audio then converted.with(convert_audio: true)
        elsif hardware && !now.software then converted.with(software: true)
        end
      else T.absurd(method)
      end
    end

    # Converted on a hardware encoder: here, or on a remote transcoder.
    sig { params(session: PlaybackSession).returns(T::Boolean) }
    def self.hardware?(session)
      return false if session.constraints.software

      !session.transcode_node_id.nil? || Encoders.kind.hardware?
    end

    # What failed is recorded on the session and it ends. What failed for
    # this file here is remembered — unless it was the evening's doing, not
    # the file's (R3).
    sig do
      params(failed: PlaybackSession, failure: PlaybackSession::FailureClass, position: Float, reported: T.nilable(String)).void
    end
    def self.record!(failed, failure, position:, reported:)
      # The transcoder's own words when it was the transcoder that gave up.
      own = failure == PlaybackSession::FailureClass::Server ? failed.transcode_error : nil
      cause = own || reported || failed.transcode_error
      failed.update!(failure_class: failure.serialize, failure_cause: cause, failed_at: Time.current, position_seconds: position)
      failed.end!
      Learned.failed!(failed) unless passing?(failed, failure)
      PlaybackEvent.create!(playback_session: failed, kind: PlaybackEvent::Kind::Error.serialize, position_seconds: position,
        detail: { "message" => "fell back (#{failure.serialize})", "cause" => cause }.compact, created_at: Time.current)
      Lucid.increment("playback.fallbacks", tags: { method: failed.method, failure: failure.serialize })
    end

    # A failure about the evening rather than the file: a stall, the
    # network, or a transcoder that gave up on a run that stalled or lost
    # its node.
    sig { params(session: PlaybackSession, failure: PlaybackSession::FailureClass).returns(T::Boolean) }
    def self.passing?(session, failure)
      return true if failure.transient?
      return false unless failure == PlaybackSession::FailureClass::Server

      last = TranscodeRun.where(playback_session_id: session.id).failed.order(:created_at).last
      [ TranscodeRun::Failure::Stalled, TranscodeRun::Failure::Lost ].include?(last&.failure_enum)
    end

    # The next rung down from a failed session that really is another way
    # to play it: a step that changes nothing here (no sound to convert,
    # say) is taken past. A copy that would wait on a keyframe index goes
    # on to converting instead — a fallback never waits.
    sig do
      params(failed: PlaybackSession, file: MediaFile, failure: PlaybackSession::FailureClass).returns(T.nilable(Plan::Placed))
    end
    def self.descend(failed, file, failure)
      stored = failed.stored_decision
      upgraded_from = stored.upgraded_from
      return place_and_fit(failed, file, upgraded_from) if upgraded_from

      method = failed.method_enum
      constraints = failed.constraints
      before = stored.how_played
      hardware = hardware?(failed)
      5.times do
        step = next_constraints_for(method, constraints, failure, hardware: hardware)
        return nil if step.nil?

        constraints = step
        trial = Plan.again(failed, file, constraints, reason(failed)).decide(Encoders.max_height)
        return nil unless trial.playable?

        if trial.video&.copy && trial.method.streamed? && !Media::KeyframeIndex.ready_for_play!(file)
          constraints = constraints.with(convert_video: true)
          trial = Plan.again(failed, file, constraints, reason(failed)).decide(Encoders.max_height)
        end
        changed = trial.to_h.slice("method", "video", "audio") != before || constraints.software != failed.constraints.software
        return place_and_fit(failed, file, constraints) if changed

        method = trial.method
      end
      nil
    end

    # What a play that fell back for a passing reason (a stall, the network)
    # would climb back to (R2, "Upgrading back"): the rung it fell from, when
    # that's better than where it is and needn't wait on anything.
    sig { params(lower: PlaybackSession, file: MediaFile).returns(T.nilable(Decision)) }
    def self.upgrade(lower, file)
      from = lower.fallback_from
      return nil unless from && lower.active? && lower.stored_decision.transient_fallback?

      decision = Plan.again(lower, file, from.constraints, nil).decide(Encoders.max_height)
      return nil unless decision.playable? && Start::COST.fetch(decision.method) < Start::COST.fetch(lower.method_enum)
      return nil if decision.video&.copy && decision.method.streamed? && !Media::KeyframeIndex.ready_for_play!(file)

      decision
    end

    # Where a conversion runs decides how tall it can be, and past the
    # limit it's made smaller rather than refused (as a first play is).
    sig { params(failed: PlaybackSession, file: MediaFile, constraints: Constraints).returns(Plan::Placed) }
    def self.place_and_fit(failed, file, constraints)
      why = failed.stored_decision.upgrade? ? nil : reason(failed)
      # Converting in software here: nowhere else to put it, and only so tall.
      height = constraints.software ? Encoders.max_height_for(Encoders::Kind::Software) : Encoders.max_height
      Plan.again(failed, file, constraints, why).place_and_fit(height, place: !constraints.software)
    end
    private_class_method :place_and_fit

    # Why the play is on a lower rung, for the decision's reasons.
    sig { params(session: PlaybackSession).returns(String) }
    def self.reason(session)
      "#{session.method_enum.label} didn't play (#{describe(session)}) — fell back"
    end

    # What happened on each rung tried, for the message when none is left.
    sig { params(chain: T::Array[PlaybackSession], device: String).returns(String) }
    def self.given_up(chain, device)
      tried = chain.select(&:failure_class).map { |session| "#{session.method_enum.label.downcase}: #{describe(session)}" }
      "This couldn't be played on #{device}. Tried #{tried.join('; ')}."
    end

    sig { params(session: PlaybackSession).returns(String) }
    def self.describe(session)
      failure = session.failure_class_enum
      what = failure ? FAILURE_LABELS.fetch(failure) : "failed"
      at = session.position_seconds.positive? ? " at #{clock(session.position_seconds)}" : ""
      "#{what}#{at}"
    end
    private_class_method :describe

    sig { params(seconds: Float).returns(String) }
    def self.clock(seconds)
      whole = seconds.to_i
      hours, rest = whole.divmod(3600)
      minutes, secs = rest.divmod(60)
      hours.positive? ? format("%<h>d:%<m>02d:%<s>02d", h: hours, m: minutes, s: secs) : format("%<m>d:%<s>02d", m: minutes, s: secs)
    end
    private_class_method :clock

    FAILURE_LABELS = T.let({
      PlaybackSession::FailureClass::Decode => "the browser couldn't decode it",
      PlaybackSession::FailureClass::Unsupported => "the browser wouldn't open it",
      PlaybackSession::FailureClass::Stalled => "it stopped getting anywhere",
      PlaybackSession::FailureClass::Network => "the network gave up",
      PlaybackSession::FailureClass::Server => "the transcoder gave up"
    }.freeze, T::Hash[PlaybackSession::FailureClass, String])
  end
end
