# typed: strict
# frozen_string_literal: true

module LiveStreams
  # ffprobe on a live stream's address (PROPOSAL §7.8): when it's saved, and
  # again when its relay can't start. What it finds becomes MediaStream rows
  # the decision engine reads, exactly as a file's do, so play never probes
  # (CLAUDE.md invariant 4); every run leaves an AnalysisRun. Whatever ffprobe
  # says passes through LiveStream#redact before it's kept or shown.
  module Prober
    extend T::Sig

    # A camera answers in a second or two; a web stream fetches a playlist
    # and a segment or two first.
    TIMEOUT = 30

    class Failure < StandardError; end

    class Result < T::Struct
      const :container, T.nilable(String)
      const :streams, T::Array[T::Hash[Symbol, T.untyped]]
    end

    # Probes and records: the rows, the status, and the AnalysisRun. probed:
    # what a probe a moment ago found, for a stream saved only once it had
    # been read (Settings), rather than asking the camera twice.
    sig { params(stream: LiveStream, probed: T.nilable(Result)).returns(Result) }
    def self.call(stream, probed: nil)
      result = AnalysisRun.track(stream, AnalysisRun::Step::Probe, tool_version: ToolRunner.version("ffprobe")) { probed || probe(stream) }
      LiveStream.transaction do
        stream.media_streams.delete_all
        now = Time.current
        rows = result.streams.map { |row| row.merge(live_stream_id: stream.id, created_at: now, updated_at: now) }
        MediaStream.insert_all!(rows) if rows.any?
        stream.update!(container: result.container, probed_at: now, status: LiveStream::Status::Online.serialize,
          last_seen_at: now, last_error: nil, last_error_at: nil, consecutive_failures: 0)
      end
      stream.media_streams.reset
      result
    rescue Failure => e
      offline!(stream, e.message)
      raise
    end

    # A source that couldn't be reached, as its card and Needs attention say.
    sig { params(stream: LiveStream, message: String).void }
    def self.offline!(stream, message)
      return unless stream.persisted?

      stream.update_columns( # rubocop:disable Rails/SkipsModelValidations
        status: LiveStream::Status::Offline.serialize, last_error: stream.redact(message).truncate(250),
        last_error_at: Time.current, consecutive_failures: stream.consecutive_failures + 1, updated_at: Time.current
      )
    end

    # Probes without recording anything: the Test button, and a new stream
    # before it's saved. Sound sent apart (YouTube) is probed as well, its
    # tracks numbered on after the picture's.
    sig { params(stream: LiveStream).returns(Result) }
    def self.probe(stream)
      input = Playback::FfmpegArgs::Input.live(stream)
      raw, streams = ffprobe(stream, input)
      video = streams.find { |row| row[:kind] == MediaStream::Kind::Video.serialize }
      raise Failure, "There's no video in this stream" if video.nil?

      sound = input.audio
      if sound
        offset = streams.map { |row| row[:index].to_i }.max.to_i + 1
        streams += ffprobe(stream, sound).last.select { |row| row[:kind] == MediaStream::Kind::Audio.serialize }
          .map { |row| row.merge(index: row[:index].to_i + offset) }
      end
      Result.new(container: raw.dig("format", "format_name"), streams: streams)
    end

    sig { params(stream: LiveStream, input: Playback::FfmpegArgs::Input).returns([ T::Hash[String, T.untyped], T::Array[T::Hash[Symbol, T.untyped]] ]) }
    def self.ffprobe(stream, input)
      argv = [ "ffprobe", "-v", "error" ] + input.options +
        [ "-protocol_whitelist", input.protocols, "-print_format", "json", "-show_format", "-show_streams", "-i", input.url ]
      begin
        output = ToolRunner.run(argv, timeout: TIMEOUT)
      rescue ToolRunner::Timeout
        raise Failure, "#{stream.source} didn't answer within #{TIMEOUT} seconds"
      end
      raw = Media::Probe.parse(output.stdout)
      streams = Media::Probe.streams_from(raw)
      raise Failure, explain(stream, output.stderr) if !output.success? || streams.empty?

      [ raw, streams ]
    end
    private_class_method :ffprobe

    # ffprobe's complaint as a person would put it, never with the address.
    sig { params(stream: LiveStream, stderr: String).returns(String) }
    def self.explain(stream, stderr)
      source = stream.source
      case stderr
      when /option (\S+) not found/i
        "This server's ffmpeg doesn't take the option #{Regexp.last_match(1)}: update Stream, or say so"
      when /certificate|verification failed/i
        "#{source}'s certificate isn't trusted. A camera usually has its own: turn on Trust its certificate"
      when /401|unauthori[sz]ed|authentication/i then "#{source} refused the sign-in in the address"
      when /403|forbidden/i then "#{source} refused to send the stream (403)"
      when /404|not found/i then "Nothing's at that address on #{source} (404)"
      when /5\d\d|server error/i then "#{source} answered with an error"
      when /connection refused/i then "Nothing answered at #{source}"
      when /timed out|timeout|immediate exit/i
        "#{source} didn't send a stream in time. Check the address is the one the camera or site gives now"
      when /no route|unreachable|resolve|name or service|nodename/i then "#{source} can't be reached from this server"
      else
        line = stderr.lines.map(&:strip).find(&:present?).to_s.sub(/\A\[[^\]]*\]\s*/, "")
        line.empty? ? "#{source} didn't send a stream" : stream.redact(line)
      end
    end
  end
end
