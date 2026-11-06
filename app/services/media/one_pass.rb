# typed: strict
# frozen_string_literal: true

module Media
  # One read of a file for every whole-file step it still needs (PROPOSAL
  # §5.5): the seek-bar thumbnails, the keyframe index when the container
  # has none, the loudness, and the embedded subtitles and fonts. Each used
  # to be a read of its own — four passes over a 137 GB remux, at the 6 MB/s
  # its share manages, is a day — and now ffmpeg makes all of them from the
  # same packets. A step already done costs nothing; a step that fails
  # records its own AnalysisRun, and the next read does only what's still
  # missing.
  module OnePass
    extend T::Sig

    # How long the read may stand still. A busy share reads at single-digit
    # MB/s, so how long it takes is the share's business, and only a read
    # that stops is given up on. Generous, because frame threading holds
    # back a keyframe per decoder thread before the first one comes out:
    # minutes of a 4K remux, busy.
    QUIET_TIMEOUT = 600

    # Keyframes only, for every codec. `-skip_frame nokey` asks the decoder,
    # and VP9's ignores it (a long VP9 file decoded every frame and ran past
    # the timeout); `-discard nokey` asks the demuxer, and Matroska/WebM's
    # ignores that. An input bitstream filter drops the packets before either
    # sees them.
    KEYFRAMES_ONLY = T.let([ "-skip_frame", "nokey", "-bsf:v", "noise=drop=not(key)" ].freeze, T::Array[String])

    # Subtitles are sparse — minutes of film can pass without a cue — so a
    # read that decodes nothing keeps time by one more output: the first
    # audio track copied to nowhere, which moves with the read.
    PACE_OUTPUT = T.let(%w[-map 0:a:0 -c copy -f null -].freeze, T::Array[String])

    # One step's share of the read: what it adds to ffmpeg's argv, and what
    # it makes of the result.
    class Part
      extend T::Sig
      extend T::Helpers
      abstract!

      sig { abstract.returns(AnalysisRun::Step) }
      def step; end

      # What it makes isn't there (a restore left it out, a file is new).
      sig { abstract.returns(T::Boolean) }
      def missing?; end

      # Whether a run of its step that didn't succeed is reason enough to do
      # it again. The keyframe index is the exception: IndexKeyframesJob owns
      # that step, and this read only fills an index that isn't there.
      sig { overridable.returns(T::Boolean) }
      def again? = true

      # Whether it needs ffmpeg at all this time (a file with no embedded
      # subtitles has a subtitles step with nothing to make).
      sig { overridable.returns(T::Boolean) }
      def work? = true

      # Needs the picture decoded (keyframes only), and may filter it.
      sig { overridable.returns(T::Boolean) }
      def decodes_video? = false

      # Its chain of the filter graph, fed decoded keyframes under the label
      # it's given, or nil for a part that only needs them counted.
      sig { overridable.params(input: String).returns(T.nilable(String)) }
      def video_chain(input) = nil

      # ffmpeg's log level the part reads its answer from.
      sig { overridable.returns(String) }
      def log_level = "error"

      # Before the read: a directory to write into.
      sig { overridable.void }
      def prepare; end

      # Options before -i.
      sig { overridable.returns(T::Array[String]) }
      def input_args = []

      # Its outputs, after the input: one argv fragment per output file, so
      # a failure ffmpeg lays at an output's door can be laid at the part's.
      sig { overridable.returns(T::Array[T::Array[String]]) }
      def outputs = []

      # After the read: what to keep. keyframes_ms is every keyframe the
      # decoder saw, in order of arrival, when the picture was decoded.
      sig { abstract.params(result: T.nilable(ToolRunner::Result), keyframes_ms: T::Array[Integer]).void }
      def finish(result, keyframes_ms); end

      # After a failure: leave nothing half-made behind.
      sig { overridable.void }
      def discard; end
    end

    # ffmpeg laid the failure at one output's door: that part's, and the
    # next read leaves it out (parts_for) until it's asked for again.
    class OutputError < ToolRunner::Error; end

    # The read failed, and with it every part's share of it.
    class ReadFailed < ToolRunner::Error
      extend T::Sig

      sig { returns(T.nilable(Part)) }
      attr_reader :guilty

      sig { params(message: String, guilty: T.nilable(Part)).void }
      def initialize(message, guilty: nil)
        super(message)
        @guilty = guilty
      end
    end

    # Keyframes alone: the index of a file whose container has none, from
    # the packets the thumbnails are decoded from anyway. Checked the way
    # the packet scan checks its own (Keyframes::PacketScan).
    class KeyframesPart < Part
      sig { params(file: MediaFile).void }
      def initialize(file)
        @file = file
      end

      sig { override.returns(AnalysisRun::Step) }
      def step = AnalysisRun::Step::Keyframes

      sig { override.returns(T::Boolean) }
      def missing? = @file.keyframes.nil?

      sig { override.returns(T::Boolean) }
      def again? = false

      sig { override.returns(T::Boolean) }
      def decodes_video? = true

      sig { override.params(result: T.nilable(ToolRunner::Result), keyframes_ms: T::Array[Integer]).void }
      def finish(result, keyframes_ms)
        times = Keyframes::PacketScan.complete!(keyframes_ms, duration_seconds: @file.duration_seconds)
        KeyframeIndex.store(@file, times, KeyframeIndex::Source::Packets)
      rescue Keyframes::PacketScan::Incomplete
        # A damaged file reads the same way every time (its AnalysisRun says
        # so in Needs attention): no index, so it's converted, and not
        # scanned again on every press of Play.
        KeyframeIndex.store(@file, [], KeyframeIndex::Source::None)
        raise
      end
    end

    # Whether a read would do anything for this file.
    sig { params(file: MediaFile).returns(T::Boolean) }
    def self.needed?(file) = parts_for(file).any?

    # Every whole-file step the file still needs, in one read. Returns the
    # steps that succeeded; raises the first failure (recorded on its
    # AnalysisRun) after every part has had its turn at the result.
    sig { params(file: MediaFile, hold: T.nilable(ToolRunner::Hold)).returns(T::Array[AnalysisRun::Step]) }
    def self.run(file, hold: nil)
      parts = parts_for(file)
      return [] if parts.empty?

      runs = parts.map { |part| AnalysisRun.begin!(file, part.step) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      keyframes = T.let([], T::Array[Integer])
      begin
        result = parts.any?(&:work?) ? read(file, parts.select(&:work?), hold) { |times| keyframes = times } : nil
      rescue StandardError => e
        parts.each(&:discard)
        guilty = e.is_a?(ReadFailed) ? e.guilty : nil
        parts.zip(runs).each do |part, run|
          T.must(run).fail!(if part == guilty then OutputError.new(e.message)
          elsif guilty then ReadFailed.new("the read failed on #{guilty.step.serialize}'s output: #{e.message}")
          else e
          end)
        end
        raise
      end

      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      version = ToolRunner.version("ffmpeg")
      failures = T.let([], T::Array[StandardError])
      done = parts.zip(runs).filter_map do |part, run|
        finish(part, T.must(run), result, keyframes, elapsed, version, failures)
      end
      # A damaged file's keyframes are recorded as none to be had, and
      # that's that; anything else is the job's to try again.
      failure = failures.find { |error| !error.is_a?(Keyframes::PacketScan::Incomplete) }
      raise failure if failure

      done
    end

    sig do
      params(part: Part, run: AnalysisRun, result: T.nilable(ToolRunner::Result), keyframes: T::Array[Integer], elapsed: Integer,
        version: T.nilable(String), failures: T::Array[StandardError]).returns(T.nilable(AnalysisRun::Step))
    end
    def self.finish(part, run, result, keyframes, elapsed, version, failures)
      part.finish(result, keyframes)
      run.succeed!(duration_ms: elapsed, tool_version: version)
      part.step
    rescue StandardError => e
      part.discard
      run.fail!(e)
      failures << e
      nil
    end
    private_class_method :finish

    # The block, with no other read of this file under way; nil, without
    # running it, when one is. One read per file at a time is the job's
    # concurrency key, but a keyframe packet scan is a read of the file too
    # (IndexKeyframesJob), and a semaphore that ran out lets one arrive beside it.
    sig { type_parameters(:R).params(file: MediaFile, blk: T.proc.returns(T.type_parameter(:R))).returns(T.nilable(T.type_parameter(:R))) }
    def self.exclusively(file, &blk)
      connection = ActiveRecord::Base.lease_connection
      key = ActiveRecord::Base.sanitize_sql_array([ "hashtext('media_one_pass'), hashtext(?)", file.id ])
      return nil unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")

      begin
        yield
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{key})")
      end
    end

    sig { params(file: MediaFile).returns(T::Array[Part]) }
    def self.parts_for(file)
      video = file.primary_video
      candidates = T.let([], T::Array[Part])
      audio = file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Audio }
      candidates << TrickplayBuilder::Part.new(file, video) if video && video.width.to_i.positive?
      candidates << KeyframesPart.new(file) if video
      candidates << Loudness::Part.new(file, audio) if audio
      candidates << Subtitles::Extractor::Part.new(file)
      runs = AnalysisRun.where(media_file: file, step: candidates.map { |part| part.step.serialize }).index_by(&:step_enum)
      candidates.select do |part|
        run = runs[part.step]
        # Its output failed the last read: left out, so the rest get done,
        # until it's asked for again (Analysis::Rerun) — Needs attention says so.
        next false if run && run.status_enum == AnalysisRun::Status::Failed && run.error.to_s.start_with?(OutputError.name.to_s)

        part.missing? || (part.again? && !(run && run.succeeded?))
      end
    end

    # ffmpeg over the whole file, every part's outputs at once, in the
    # file's own timestamps (-copyts): what the keyframe index must be in,
    # and what a container's start time means for the rest is each part's
    # to allow for (Playback::FfmpegArgs.start_time, the player's zero).
    # Its stdout is the read's pulse: with the picture decoded, each
    # keyframe's time as it comes out (which is also the index); otherwise
    # -progress, which moves with the loudness output or the pace output.
    sig do
      params(file: MediaFile, parts: T::Array[Part], hold: T.nilable(ToolRunner::Hold),
        blk: T.proc.params(keyframes_ms: T::Array[Integer]).void).returns(ToolRunner::Result)
    end
    def self.read(file, parts, hold, &blk)
      parts.each(&:prepare)
      video = parts.any?(&:decodes_video?) ? file.primary_video : nil
      level = parts.map(&:log_level).include?("info") ? "info" : "error"
      argv = [ "ffmpeg", "-hide_banner", "-nostdin", "-nostats", "-v", level, "-y", "-copyts" ]
      argv += video ? KEYFRAMES_ONLY : [ "-progress", "pipe:1" ]
      # AVI's packets carry no presentation time at all: +genpts makes them
      # one.
      argv += [ "-fflags", "+genpts", *parts.flat_map(&:input_args), "-protocol_whitelist", "file", "-i", "file:#{file.path}" ]
      outputs = T.let([], T::Array[[ T.nilable(Part), T::Array[String] ]])
      if video
        branches = parts.filter_map do |part|
          label = "[#{part.step.serialize}]"
          chain = part.video_chain(label)
          [ label, chain ] if chain
        end
        if branches.any?
          labels = branches.map(&:first)
          argv += [ "-filter_complex", [ "[0:#{video.index}]split=#{labels.size}#{labels.join}", *branches.map(&:last) ].join(";") ]
        end
        # Every decoded keyframe's time, to stdout, as it's encoded to
        # nothing: in the stream's own time base, so it's the packet's.
        # Straight from the decoder, beside the filter graph and not out of
        # it: a graph's outputs wait on each other, so inside it these lines
        # came only when a trickplay sheet filled (1,000 seconds of film),
        # and a healthy read on a busy share went quiet for that long.
        outputs << [ nil, [ "-map", "0:#{video.index}", "-c:v", "wrapped_avframe", "-enc_time_base", "demux", "-fps_mode", "passthrough",
          "-stats_enc_pre", "pipe:1", "-stats_enc_pre_fmt", "{t}", "-f", "null", "-" ] ]
      end
      parts.each { |part| part.outputs.each { |output| outputs << [ part, output ] } }
      paced = video.nil? && parts.none? { |part| part.log_level == "info" } &&
        file.media_streams.any? { |stream| stream.kind_enum == MediaStream::Kind::Audio }
      outputs << [ nil, PACE_OUTPUT ] if paced
      argv += outputs.flat_map(&:last)

      result = if video
        times = T.let([], T::Array[Integer])
        ToolRunner.each_line(argv, idle_timeout: QUIET_TIMEOUT, hold: hold) do |line|
          seconds = Float(line.strip, exception: false)
          times << (seconds * 1000).round if seconds
        end.tap { blk.call(times) }
      else
        ToolRunner.run_advancing(argv, stall_timeout: QUIET_TIMEOUT, hold: hold)
      end
      return result if result.success?

      # ffmpeg names the output stream (vost#1:0) or file (out#1) a failure
      # is about; a failure of the input is nobody's in particular.
      blamed = result.stderr.lines.find do |line|
        line.match?(/\A\[(?:[vas]ost|out)#\d+/) && line.match?(/error|could not|nothing was written|unknown|invalid|failed/i)
      end
      guilty = blamed && outputs[blamed[/#(\d+)/, 1].to_i]&.first
      raise ReadFailed.new(result.stderr.strip.lines.last.to_s.strip.presence || "ffmpeg exited #{result.status}", guilty: guilty)
    end
    private_class_method :read
  end
end
