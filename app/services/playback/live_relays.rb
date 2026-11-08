# typed: strict
# frozen_string_literal: true

module Playback
  # The transcoder's live streams (PROPOSAL §7.8): one ffmpeg per stream and
  # decision, pulling the address and writing live HLS into the cache
  # (LiveCache), shared by everyone watching it that way. It starts when web
  # asks (Signal.relay), keeps going while someone fetches its playlist,
  # and stops a minute after the last — unless the stream is kept connected,
  # when one relay runs all the time and pressing play joins it at once. When the source drops it reconnects,
  # backing off, and says so (`reconnecting`) rather than ending: a camera
  # that reboots comes back on its own.
  class LiveRelays
    extend T::Sig

    # Nobody has fetched its playlist in this long: stopped, and its files
    # deleted.
    IDLE = 60.0
    # Seconds before each reconnect, the last repeating.
    BACKOFF = T.let([ 1, 2, 5, 10, 30 ].freeze, T::Array[Integer])
    # Running but not a new segment in this long: stuck, so started again.
    STALL = 30.0
    # How often a live relay refreshes its stream's last_seen_at, and clears
    # out segments its playlist no longer names (LiveCache.prune!).
    SEEN_EVERY = 60.0
    # How often the streams kept connected are looked for.
    KEPT_EVERY = 10.0

    class Relay < T::Struct
      const :key, String
      const :stream_id, String
      # What it relays: copied or converted, which tracks (Decision#to_h).
      const :decision, T::Hash[String, T.untyped]
      prop :handle, T.nilable(Runner::Handle), default: nil
      prop :started_at, Float, default: 0.0
      # When its playlist was last seen with a fresh segment in it.
      prop :heard_at, Float, default: 0.0
      prop :failures, Integer, default: 0
      prop :retry_at, T.nilable(Float), default: nil
      prop :live, T::Boolean, default: false
      prop :seen_at, Float, default: 0.0
      # A YouTube or MLB.tv stream's playlists, and the thread asking yt-dlp
      # for them.
      prop :resolved, T.nilable(LiveStreams::Resolved), default: nil
      prop :resolving, T.nilable(Thread), default: nil
    end

    sig { params(encoder: Encoders::Kind, log: T.proc.params(message: String).void).void }
    def initialize(encoder: Encoders.kind, log: ->(message) { Rails.logger.info("[transcoder] #{message}") })
      @profile = T.let(Encoders::Profile.local(encoder), Encoders::Profile)
      @log = log
      @relays = T.let({}, T::Hash[String, Relay])
      @kept_at = T.let(0.0, Float)
      # What a transcoder before this one left behind is nobody's now.
      FileUtils.rm_rf(LiveCache.root)
    end

    sig { returns(T::Hash[String, Relay]) }
    attr_reader :relays

    # Someone pressed play on a live stream (or its player fetched the
    # playlist): make sure its relay is running, or about to.
    sig { params(session_id: String).void }
    def request(session_id)
      session = PlaybackSession.unscoped.find_by(id: session_id)
      return if session.nil? || !session.active? || session.playable_type != "LiveStream"

      key = LiveCache.key_for(session)
      return if @relays.key?(key)

      relay = Relay.new(key: key, stream_id: session.playable_id, decision: session.decision)
      @relays[key] = relay
      start(relay)
    end

    # The streams kept connected, each relayed as any browser would take it
    # but copying its picture whatever the codec (KEPT): kept wanted, so the
    # relay never goes idle, and started if it isn't running. One that's
    # no longer kept goes idle like any other.
    sig { void }
    def keep_connected
      now = monotonic
      return if now - @kept_at < KEPT_EVERY

      @kept_at = now
      LiveStream.unscoped.where(keep_connected: true).includes(:media_streams).find_each do |stream|
        decision = Decision.live(stream, KEPT).to_h
        next unless decision["refusal"].nil?

        key = LiveCache.key(stream.id, decision)
        LiveCache.want!(key)
        next if @relays.key?(key)

        relay = Relay.new(key: key, stream_id: stream.id, decision: decision)
        @relays[key] = relay
        start(relay)
      end
    end

    # What a kept connection is relayed for: any picture copied, the sound
    # as every browser plays it.
    KEPT = T.let(Capabilities.from_json("video" => Capabilities::VIDEO_KEYS, "hdr" => Capabilities::HDR_KEYS, "max_height" => 4320),
      Capabilities)

    # Reap what exited, reconnect what's due, stop what nobody wants.
    sig { void }
    def tick
      keep_connected
      now = monotonic
      @relays.values.each do |relay|
        wanted = LiveCache.wanted_at(relay.key)
        next stop(relay, "nobody's watching") if wanted.nil? || Time.current - wanted > IDLE

        handle = relay.handle
        if handle
          exit = Runner.poll(handle)
          next failed(relay, exit_message(relay, exit)) if exit

          watch(relay, now)
        elsif relay.resolving
          resolved(relay)
        elsif (due = relay.retry_at) && now >= due
          start(relay)
        end
      end
    end

    sig { void }
    def stop_all
      @relays.values.each { |relay| stop(relay, "the transcoder is stopping") }
    end

    # Running here: what the transcoder's heartbeat and optimizing care about.
    sig { returns(T::Boolean) }
    def converting? = @relays.values.any? { |relay| relay.handle && !relay_copy?(relay) }

    private

    sig { params(relay: Relay).void }
    def start(relay)
      stream = LiveStream.unscoped.includes(:media_streams).find_by(id: relay.stream_id)
      return stop(relay, "the stream was removed") if stream.nil?

      return resolve(relay, stream) if LiveStreams::Resolver.needed?(stream) && relay.resolved.nil?

      directory = LiveCache.directory(relay.key)
      FileUtils.mkdir_p(directory)
      argv = LiveArgs.build(stream, relay.decision, directory: directory, profile: @profile, append: LiveCache.playlist(relay.key).file?,
        resolved: relay.resolved)
      relay.handle = Runner.spawn_local(argv, log: directory.join("ffmpeg.log"), redact: ->(text) { stream.redact(text) })
      relay.started_at = monotonic
      relay.heard_at = relay.started_at
      relay.retry_at = nil
      relay.live = false
      LiveCache.write_status(relay.key, relay.failures.zero? ? "starting" : "reconnecting", LiveCache.status(relay.key)&.message)
      @log.call("live #{stream.name}: #{relay.failures.zero? ? 'relaying' : 'reconnecting'} (#{stream.source})")
      Glass.increment("live.relays", tags: { kind: stream.kind, reconnect: relay.failures.positive?.to_s })
    end

    # yt-dlp takes seconds (and the first time, tens): on a thread of its
    # own, so the loop answering seeks never waits for it. The relay starts
    # on the tick after it answers.
    sig { params(relay: Relay, stream: LiveStream).void }
    def resolve(relay, stream)
      relay.retry_at = nil
      relay.resolving = Thread.new do
        Thread.current.report_on_exception = false
        Rails.application.executor.wrap { LiveStreams::Resolver.resolve(stream) }
      end
      LiveCache.write_status(relay.key, relay.failures.zero? ? "starting" : "reconnecting", LiveCache.status(relay.key)&.message)
    end

    sig { params(relay: Relay).void }
    def resolved(relay)
      thread = T.must(relay.resolving)
      return if thread.alive?

      relay.resolving = nil
      relay.resolved = thread.value
      start(relay)
    rescue LiveStreams::Prober::Failure => e
      failed(relay, e.message)
    rescue StandardError => e
      Rails.error.report(e, handled: true, source: "transcoder")
      failed(relay, "Couldn't ask yt-dlp for the stream (#{e.class})")
    end

    # A run that's going: live once its first segment lands, stuck if no
    # new one does for STALL. Stuck is measured from the last time the
    # playlist was seen moving, not from one look: on the NFS cache a read
    # can miss while ffmpeg renames a new playlist into place, and that
    # isn't a stream that stopped.
    sig { params(relay: Relay, now: Float).void }
    def watch(relay, now)
      changed = begin
        File.mtime(LiveCache.playlist(relay.key)).to_f
      rescue SystemCallError
        nil
      end
      if changed && Time.current.to_f - changed <= STALL && LiveCache.ready?(relay.key)
        relay.heard_at = now
        went_live(relay) unless relay.live
        return unless now - relay.seen_at > SEEN_EVERY

        relay.seen_at = now
        LiveStream.unscoped.where(id: relay.stream_id).update_all(last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        LiveCache.prune!(relay.key)
        return
      end
      return unless now - relay.heard_at > STALL

      Runner.kill(T.must(relay.handle))
      failed(relay, relay.live ? "The stream stopped sending" : "No picture from the stream after #{STALL.round} seconds")
    end

    sig { params(relay: Relay).void }
    def went_live(relay)
      relay.live = true
      relay.failures = 0
      relay.seen_at = monotonic
      LiveCache.write_status(relay.key, "live")
      LiveStream.unscoped.where(id: relay.stream_id).update_all( # rubocop:disable Rails/SkipsModelValidations
        status: LiveStream::Status::Online.serialize, last_seen_at: Time.current, last_error: nil, last_error_at: nil,
        consecutive_failures: 0, updated_at: Time.current
      )
      Glass.timing("live.relay_start", ((monotonic - relay.started_at) * 1000).round)
    end

    # Reconnects after the next wait in BACKOFF; a stream that keeps failing
    # is offline on its card and in Needs attention, and its message is
    # what the player shows while it tries.
    sig { params(relay: Relay, message: String).void }
    def failed(relay, message)
      relay.handle = nil
      relay.live = false
      # A YouTube or MLB.tv playlist that's expired fails like any drop: the
      # next start asks for new ones.
      relay.resolved = nil
      relay.failures += 1
      delay = BACKOFF.fetch([ relay.failures - 1, BACKOFF.size - 1 ].min)
      relay.retry_at = monotonic + delay
      LiveCache.write_status(relay.key, "reconnecting", message)
      @log.call("live #{relay.stream_id}: #{message}; again in #{delay}s")
      Glass.increment("live.relay_failures")
      stream = LiveStream.unscoped.find_by(id: relay.stream_id)
      return if stream.nil?

      LiveStreams::Resolver.forget(stream)
      LiveStreams::Prober.offline!(stream, message)
      return unless relay.failures == 1

      Activity.record(source: "playback", event: "live_stream.dropped", severity: Activity::Severity::Warn,
        subject: stream, household_id: stream.household_id, summary: "#{stream.name}: #{message}")
    end

    # Why it stopped, as the probe would put it (LiveStreams::Prober.explain):
    # ffmpeg's last words are already redacted on their way to the log.
    sig { params(relay: Relay, exit: Runner::Exit).returns(String) }
    def exit_message(relay, exit)
      return "The stream ended" if exit.success?

      log = LiveCache.directory(relay.key).join("ffmpeg.log")
      tail = log.file? ? LogTail.read(log, bytes: LogTail::LINES_WINDOW, lines: 3) : ""
      stream = LiveStream.unscoped.find_by(id: relay.stream_id)
      return "The relay stopped (#{exit.status || 'killed'})" if stream.nil? || tail.strip.empty?

      LiveStreams::Prober.explain(stream, tail)
    end

    sig { params(relay: Relay, why: String).void }
    def stop(relay, why)
      handle = relay.handle
      Runner.kill(handle) if handle
      @relays.delete(relay.key)
      FileUtils.rm_rf(LiveCache.directory(relay.key))
      @log.call("live #{relay.stream_id}: stopped, #{why}")
    end

    sig { params(relay: Relay).returns(T::Boolean) }
    def relay_copy?(relay) = relay.decision.dig("video", "copy") == true

    sig { returns(Float) }
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
  end
end
