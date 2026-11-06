# typed: strict
# frozen_string_literal: true

module Playback
  # Plays a file one way, on this machine, the way a viewer's play would
  # run it: the production arguments, a
  # stretch from the start and one from the middle, published by the real
  # Publisher and decoded end to end. What the playability sweep and the
  # corpus spec ask of every format — so a format that can't be converted
  # is found before a viewer meets it.
  class Trial
    extend T::Sig

    # How much of each stretch is made.
    SECONDS = 20
    # What a run here may take before it's a failure in itself.
    TIMEOUT = 180

    class Outcome < T::Struct
      extend T::Sig

      const :ok, T::Boolean
      const :rung, String
      # Why, when it failed: ffmpeg's last words, the publisher's refusal,
      # or what decoding the result said.
      const :cause, T.nilable(String), default: nil
      const :seconds, Float, default: 0.0
    end

    # The ways the server can play a file, as rungs (Learned.rung).
    RUNGS = T.let({
      "remux" => Constraints::NONE.with(no_direct: true),
      "audio_transcode" => Constraints::NONE.with(no_direct: true, convert_audio: true),
      "video_transcode_software" => Constraints::NONE.with(no_direct: true, convert_audio: true, convert_video: true, software: true)
    }.freeze, T::Hash[String, Constraints])

    # What a browser decodes, broadly: the server's half of the question,
    # not any one client's.
    CAPABILITIES = T.let(Capabilities.from_json(
      "hls" => "mse", "containers" => %w[mp4], "video" => %w[h264 hevc hevc_10 av1 av1_10 vp9 vp9_10],
      "audio" => %w[aac ac3 eac3 flac opus], "max_audio_channels" => 6, "hdr" => %w[hdr10 hlg], "max_height" => 2160
    ), Capabilities)

    sig { params(file: MediaFile, rung: String).void }
    def initialize(file, rung)
      @file = file
      @rung = rung
    end

    # The decision this rung makes for the file, or nil when it's not a
    # different way to play it (no sound to convert, say).
    sig { returns(T.nilable(Decision)) }
    def decision
      decision = Decision.new(@file, CAPABILITIES, max_height: Decision::SOFTWARE_MAX_HEIGHT, device_name: "The server",
        constraints: RUNGS.fetch(@rung))
      return nil unless decision.playable?
      return nil unless decision.method.streamed?
      return nil if @rung == "audio_transcode" && decision.audio.nil?

      decision
    end

    sig { returns(T.nilable(Outcome)) }
    def run
      chosen = decision
      return nil if chosen.nil?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      plan = SegmentPlan.for(session_for(chosen))
      middle = plan.segments.fetch(plan.segment_at(((@file.duration_seconds || 0) * 500).round)).first_gop
      # Each stretch as a play of its own: what one published isn't the other's.
      cause = [ 0, middle ].uniq.lazy.filter_map do |gop|
        session = session_for(chosen)
        begin
          stretch(session, plan, gop)
        ensure
          FileUtils.rm_rf(Cache.directory(session.id))
        end
      end.first
      Outcome.new(ok: cause.nil?, rung: @rung, cause: cause, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to_f)
    end

    private

    # A play that's never saved: what the arguments and the plan are built from.
    sig { params(chosen: Decision).returns(PlaybackSession) }
    def session_for(chosen)
      PlaybackSession.new(id: SecureRandom.uuid, media_file: @file, household_id: @file.household_id, method: chosen.method.serialize,
        decision: chosen.to_h, segment_target_ms: SegmentPlan::TARGET_MS)
    end

    # One stretch made and checked; why it failed, or nil.
    sig { params(session: PlaybackSession, plan: SegmentPlan, gop: Integer).returns(T.nilable(String)) }
    def stretch(session, plan, gop)
      # Beside where it's published, as a real run's is: a fragment is
      # published by renaming it, and /tmp is another volume than the cache.
      staging = Cache.staging(session.id, "trial-#{gop}")
      FileUtils.mkdir_p(staging)
      profile = Encoders::Profile.local(Encoders::Kind::Software)
      argv = FfmpegArgs.build(session, plan, start_gop: gop, directory: staging, profile: profile)
      # Read for this long from where the run starts: an input limit, since
      # an output one counts from timestamp zero under -copyts, and a file
      # whose clock starts at 95,000 s would write nothing.
      input = T.must(argv.index("-i"))
      argv = argv[0...input].to_a + [ "-t", SECONDS.to_s ] + argv[input..].to_a
      result = ToolRunner.run(argv, timeout: TIMEOUT)
      return "ffmpeg exited #{result.status}: #{result.stderr.strip.lines.last.to_s.strip}".truncate(300) unless result.success?

      published = publish(session, plan, staging)
      return "made nothing" if published.empty?

      decoded(session, published)
    rescue Publisher::Mismatch => e
      "the fragments weren't what was planned: #{e.message}".truncate(300)
    rescue ToolRunner::Error => e
      e.message.truncate(300)
    ensure
      FileUtils.rm_rf(staging) if staging
    end

    sig { params(session: PlaybackSession, plan: SegmentPlan, staging: Pathname).returns(T::Array[Integer]) }
    def publish(session, plan, staging)
      publisher = Publisher.new(session_id: session.id, variant: 0, plan: plan)
      publisher.init(staging.join("init.mp4"))
      fragments = staging.glob("gop-*.m4s").sort_by { |path| path.basename.to_s[/\d+/].to_i }
      published = fragments.filter_map { |fragment| publisher.fragment(fragment) }
      # The run stopped at -t: what it was making is whole as far as it goes.
      held = Publisher::Held.read(staging)
      if held && held.kind == Publisher::Held::OPEN
        target = Cache.gop(session.id, held.gop)
        File.rename(held.path, target) unless target.file?
        published << held.gop
      end
      published.uniq.sort
    end

    # Everything published, played with its init, decodes without a word.
    sig { params(session: PlaybackSession, published: T::Array[Integer]).returns(T.nilable(String)) }
    def decoded(session, published)
      joined = Cache.directory(session.id).join("trial.mp4")
      File.open(joined, "wb") do |out|
        out.write(File.binread(Cache.init(session.id)))
        published.each { |gop| out.write(File.binread(Cache.gop(session.id, gop))) }
      end
      result = ToolRunner.run(%W[ffprobe -v error -count_frames -show_entries stream=codec_type,nb_read_frames -of json #{joined}], timeout: TIMEOUT)
      return "the stream doesn't decode: #{result.stderr.strip.lines.first.to_s.strip}".truncate(300) if result.stderr.present?

      frames = Array(JSON.parse(result.stdout.presence || "{}")["streams"]).find { |stream| stream["codec_type"] == "video" }
      frames && frames["nb_read_frames"].to_i.positive? ? nil : "the stream has no picture"
    end
  end
end
