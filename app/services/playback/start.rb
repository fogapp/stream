# typed: strict
# frozen_string_literal: true

module Playback
  # Pressing Play (PROPOSAL §6.2), past what the request says: which file,
  # how it plays, and the session that plays it, already warming when a
  # stream is what was chosen. A fallback or an upgrade starts its session
  # here too, so every session begins the same way.
  module Start
    extend T::Sig

    # How a method ranks when picking between versions: cheapest first.
    COST = T.let({
      PlaybackSession::Method::Direct => 0, PlaybackSession::Method::Remux => 1,
      PlaybackSession::Method::AudioTranscode => 2, PlaybackSession::Method::Optimized => 3,
      PlaybackSession::Method::VideoTranscode => 4
    }.freeze, T::Hash[PlaybackSession::Method, Integer])

    # Why a file that would repackage is converted this time.
    INDEXING_REASON = "Its keyframe index is still being made — converted this time, repackaged next"

    # What a press of Play brought with it.
    class Client < T::Struct
      const :capabilities, Capabilities
      const :device_name, String
      const :client_class, String
      const :audio_index, T.nilable(Integer)
      const :burn_subtitle, T.nilable(Integer)
    end

    # The file asked for (`wanted`), else the one that plays most cheaply
    # here, largest first among equals. Each from what plays on this kind of
    # client have taught (R3).
    sig do
      params(playable: T.any(Movie, Episode, Extra, Video, Clip), client: Client, max_height: Integer, wanted: T.nilable(String))
        .returns(T.nilable([ MediaFile, Decision ]))
    end
    def self.choose(playable, client, max_height, wanted:)
      files = playable.media_files.playable.includes(:media_streams, :optimized_version).to_a
      pinned = files.find { |file| file.id == wanted.to_s }
      # What plays taught, read once for every file weighed here; `place`
      # starts from the chosen decision's copy rather than asking again.
      learned = Learned.constraints_for_all(pinned ? [ pinned ] : files, client.client_class)
      decide = ->(file) do
        constraints, why = learned.fetch(file.id)
        Decision.new(file, client.capabilities, audio_index: client.audio_index, max_height: max_height, device_name: client.device_name,
          burn_subtitle: client.burn_subtitle, constraints: constraints, fell_back: why)
      end
      return [ pinned, decide.call(pinned) ] if pinned

      files.map { |file| [ file, decide.call(file) ] }
        .min_by { |file, decision| [ decision.playable? ? 0 : 1, COST.fetch(decision.method), -file.size ] }
    end

    # The chosen decision, put where it runs. A copy that would wait on a
    # keyframe index is converted now instead; the index is made meanwhile
    # and the next play repackages. What plays taught (Learned) comes with
    # `chosen`, which `choose` decided from it.
    # Nothing waits on it.
    sig { params(file: MediaFile, chosen: Decision, client: Client, max_height: Integer).returns(Plan::Placed) }
    def self.place(file, chosen, client, max_height)
      unindexed = chosen.video&.copy && chosen.method.streamed? &&
        !ActiveSupport::Notifications.instrument("keyframes.stream") { Media::KeyframeIndex.ready_for_play!(file) }
      learned = chosen.constraints
      learned_why = chosen.fell_back
      plan = Plan.new(file, client.capabilities, audio_index: client.audio_index, device_name: client.device_name,
        burn_subtitle: client.burn_subtitle, constraints: unindexed ? learned | Constraints.new(no_direct: true, convert_video: true) : learned,
        fell_back: unindexed ? INDEXING_REASON : learned_why)
      # Only a video conversion cares where it runs; the rest never ask.
      plan.place_and_fit(max_height, first: unindexed ? nil : chosen)
    end

    # A session of a file, warming if it's a stream. `live` says how the
    # play counts in Glass.
    sig do
      params(decision: Decision, position: Float, live: String, attributes: T::Hash[Symbol, T.untyped], note: T::Hash[String, T.untyped],
        announce: T::Boolean).returns(PlaybackSession)
    end
    def self.file(decision, position:, live:, attributes:, note: {}, announce: true)
      session = create(decision, live, attributes, note)
      warm(session, position) if decision.method.streamed?
      announced(session, position) if announce
      session
    end

    # A session of a live stream: its relay is asked for at once, so it's
    # connecting while the player loads.
    sig { params(decision: Decision, attributes: T::Hash[Symbol, T.untyped]).returns(PlaybackSession) }
    def self.stream(decision, attributes:)
      session = create(decision, "stream", attributes, {})
      LiveCache.want!(LiveCache.key_for(session))
      Signal.relay(session.id)
      announced(session, 0.0)
      session
    end

    sig do
      params(decision: Decision, live: String, attributes: T::Hash[Symbol, T.untyped], note: T::Hash[String, T.untyped]).returns(PlaybackSession)
    end
    def self.create(decision, live, attributes, note)
      method = decision.method.serialize
      now = Time.current
      session = PlaybackSession.create!(attributes.merge(method: method, decision: decision.to_h.merge(note),
        audio_stream_index: decision.audio&.index, started_at: now, last_seen_at: now))
      # How the household's plays go: the share that isn't direct is what
      # the transcoder costs (media invariant 3).
      Glass.increment("playback.sessions", tags: { method: method, live: live })
      Glass.tag(playback_method: method)
      session
    end
    private_class_method :create

    # Start the transcoder where the viewer will be, so the first segment is
    # ready by the time the player asks for it.
    sig { params(session: PlaybackSession, position: Float).void }
    def self.warm(session, position)
      plan = SegmentPlan.for(session)
      segment = plan.segments.fetch(plan.segment_at((position * 1000).round))
      session.update_columns(run_start: segment.first_gop) # rubocop:disable Rails/SkipsModelValidations
      Signal.request(session.id, segment.first_gop)
    end
    private_class_method :warm

    # Tuned ahead isn't watching: its start is when someone changes to it.
    sig { params(session: PlaybackSession, position: Float).void }
    def self.announced(session, position)
      return if session.standby

      PlaybackEvent.create!(playback_session: session, kind: PlaybackEvent::Kind::Start.serialize, position_seconds: position,
        created_at: Time.current)
    end
    private_class_method :announced
  end
end
