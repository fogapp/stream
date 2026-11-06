# typed: strict
# frozen_string_literal: true

module Playback
  # The web side of streaming (PROPOSAL §3.2, §6.3): playlists from the
  # plan, and segments assembled from the GOP fragments the transcoder
  # writes. Waiting for a fragment holds a Puma thread for the fraction of a
  # second it takes; the bytes themselves go out through X-Sendfile.
  class Segments
    extend T::Sig

    class Unavailable < StandardError; end
    # Whoever asked has hung up: nobody is waiting for the answer.
    class Abandoned < Unavailable; end
    # The session ended while it was waited on — changed away from, or let
    # go — so nothing will make what's asked for. Not a failure: a viewer
    # flicking past a title closes its session before its first segment.
    class Ended < Unavailable; end
    # The transcoder gave up making it (transcode_error): no point asking
    # again. The player falls back a rung instead.
    class Failed < Unavailable; end

    WAIT = 20.0
    RESIGNAL_EVERY = 2.0
    # How often a wait asks the database whether it's still worth waiting:
    # a query every 25 ms was forty a second per waiting thread.
    CHECK_EVERY = 1.0

    # gone: whether whoever is asking has hung up (ClientGone), looked at
    # while waiting, so a wait for something a seek has left behind ends
    # there instead of holding a thread — and asking the transcoder again —
    # for twenty seconds.
    sig { params(session: PlaybackSession, variant: Integer, gone: T.nilable(T.proc.returns(T::Boolean))).void }
    def initialize(session, variant = 0, gone: nil)
      @session = session
      @variant = variant
      @gone = gone
      @plan = T.let(SegmentPlan.for(session), SegmentPlan)
    end

    # The master playlist when there's more than one version: the original
    # first, so a player that starts with the first one (Safari) starts at
    # full quality. nil when there's only the original.
    sig { params(session: PlaybackSession).returns(T.nilable(String)) }
    def self.master(session)
      variants = Variants.for(session)
      return nil if variants.one?

      lines = [ "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS" ]
      variants.each do |variant|
        attributes = [ "BANDWIDTH=#{variant.bandwidth}" ]
        attributes << "RESOLUTION=#{variant.resolution}" if variant.resolution
        attributes << %(CODECS="#{variant.codecs}") if variant.codecs
        lines << "#EXT-X-STREAM-INF:#{attributes.join(',')}" << "v#{variant.index}/index.m3u8"
      end
      "#{lines.join("\n")}\n"
    end

    sig { returns(SegmentPlan) }
    attr_reader :plan

    sig { returns(String) }
    def playlist
      lines = [
        "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:#{@plan.target_duration_seconds}",
        "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MEDIA-SEQUENCE:0", '#EXT-X-MAP:URI="init.mp4"'
      ]
      @plan.segments.each_with_index do |segment, index|
        lines << format("#EXTINF:%.3f,", segment.duration_ms / 1000.0) << "seg-#{index}.m4s"
      end
      "#{(lines << '#EXT-X-ENDLIST').join("\n")}\n"
    end

    sig { returns(Pathname) }
    def init
      unless Cache.init_ready?(@session.id, @variant)
        # A smaller version is asked for mid-stream: start it where the viewer is.
        start_gop = if @variant.zero? then @session.run_start || @plan.segments.fetch(0).first_gop
        else @plan.segments.fetch(@plan.segment_at((@session.position_seconds.to_f * 1000).round)).first_gop
        end
        Signal.request(@session.id, start_gop, @variant)
        await { Cache.init_ready?(@session.id, @variant) }
      end
      raise why_not("the stream didn't start") unless Cache.init_ready?(@session.id, @variant)

      Cache.init(@session.id, @variant)
    end

    # One GOP is its own segment: the fragment ffmpeg wrote, served as it
    # is (with 2 s segments, the usual case). More are joined into one.
    sig { params(index: Integer).returns(Pathname) }
    def segment(index)
      segment = @plan.segments[index] || raise(Unavailable, "no segment #{index}")
      if segment.first_gop == segment.last_gop
        await_gop(segment.first_gop)
        return Cache.gop(@session.id, segment.first_gop, @variant)
      end

      path = Cache.segment(@session.id, index, @variant)
      return path if path.file?

      (segment.first_gop..segment.last_gop).each { |gop| await_gop(gop) }
      join(segment, path)
      path
    end

    private

    sig { params(gop: Integer).returns(T::Boolean) }
    def await_gop(gop)
      return true if Cache.gop_ready?(@session.id, gop, @variant)

      Signal.request(@session.id, gop, @variant)
      signalled = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ready = await do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now - signalled > RESIGNAL_EVERY
          Signal.request(@session.id, gop, @variant, resent: true)
          signalled = now
        end
        Cache.gop_ready?(@session.id, gop, @variant)
      end
      raise why_not("GOP #{gop} wasn't produced in #{WAIT.to_i} s") unless ready

      true
    end

    sig { params(block: T.proc.returns(T::Boolean)).returns(T::Boolean) }
    def await(&block)
      T.let(ActiveSupport::Notifications.instrument("transcoder.stream") { wait_until(&block) }, T::Boolean)
    end

    # Sleeps until the transcoder says something of this session is ready
    # (Readiness), rather than looking every 25 ms.
    sig { params(block: T.proc.returns(T::Boolean)).returns(T::Boolean) }
    def wait_until(&block)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = started + WAIT
      # An error is heeded only after a moment: one left by the run before is
      # cleared by the restart this request has just asked for (Supervisor),
      # and shouldn't fail it first.
      checked = T.let(nil, T.nilable(T.any(Float, Integer)))
      loop do
        mark = Readiness.generation(@session.id, @variant)
        return true if block.call

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if now > deadline
        raise Abandoned, "whoever asked has gone" if @gone&.call
        if checked.nil? || now - checked >= CHECK_EVERY
          # An ended session at once; an error only after a moment.
          return false if failure(errors: !checked.nil? && now - started >= CHECK_EVERY)

          checked = now
        end
        Readiness.wait(@session.id, @variant, mark)
      end
    end

    # Why waiting is over: ffmpeg failed, or the session ended — changed
    # away from, or let go — so nothing will make what's asked for, and the
    # thread is better spent on the channel changed to.
    sig { params(errors: T::Boolean).returns(T.nilable(String)) }
    def failure(errors: true)
      error, state = PlaybackSession.unscoped.where(id: @session.id).pick(:transcode_error, :state)
      return "the session ended" unless state == PlaybackSession::State::Active.serialize

      errors ? error : nil
    end

    # What a wait that came to nothing raises: Ended when the session did,
    # else what went wrong, else what didn't happen in time.
    sig { params(otherwise: String).returns(Unavailable) }
    def why_not(otherwise)
      reason = failure
      return Ended.new(reason) if reason == "the session ended"
      return Failed.new(reason) if reason

      Unavailable.new(otherwise)
    end

    # Concatenated moof/mdat pairs are one valid fMP4 segment. Written to a
    # temporary name and renamed, so a concurrent request never serves half.
    sig { params(segment: SegmentPlan::Segment, path: Pathname).void }
    def join(segment, path)
      temporary = path.sub_ext(".#{SecureRandom.hex(4)}.tmp")
      File.open(temporary, "wb") do |out|
        (segment.first_gop..segment.last_gop).each do |gop|
          File.open(Cache.gop(@session.id, gop, @variant), "rb") { |fragment| IO.copy_stream(fragment, out) }
        end
      end
      File.rename(temporary, path)
    end
  end
end
