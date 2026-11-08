# typed: strict
# frozen_string_literal: true

module Subtitles
  # Turns a track into the file the browser loads (PROPOSAL §5.5): WebVTT
  # for plain text, the original ASS for JASSUB (and WebVTT as a fallback),
  # the .sup stream for libpgs. Extracted once into storage and served from
  # there; an embedded track means reading the whole video, so the one read
  # over the file (Media::OnePass, Part below) takes every track out early,
  # and a viewer's pick only reads the file when that hasn't happened yet.
  module Extractor
    extend T::Sig

    class Error < StandardError; end

    # How long a read may stand still (ToolRunner.run_advancing); how long
    # it takes is the share's business.
    STALL_TIMEOUT = 300

    sig { returns(Pathname) }
    def self.root
      StreamPaths.storage.join("subtitles")
    end

    sig { params(file: MediaFile, track: Tracks::Track, extension: String).returns(Pathname) }
    def self.path_for(file, track, extension) = root.join(file.id.to_s, "#{track.id}.#{extension}")

    # Where OpenSubtitles downloads for a file are kept.
    sig { params(file: MediaFile).returns(Pathname) }
    def self.downloads_dir(file) = root.join(file.id.to_s, "downloaded")

    # The file for this track in this format, extracting it first if needed.
    sig { params(file: MediaFile, track: Tracks::Track, extension: String).returns(Pathname) }
    def self.fetch(file, track, extension)
      path = path_for(file, track, extension)
      return path if path.file?

      extract(file, track, extension, path)
      path
    end

    # A viewer's pick, from a job (ExtractSubtitleTrackJob) rather than the
    # request (docs/APPLETV_STALLS.md › R5): taken out, or why it couldn't
    # be, written beside where it would be so the next ask is answered at
    # once rather than read for again.
    sig { params(file: MediaFile, track: Tracks::Track, extension: String).void }
    def self.extract_for_viewer(file, track, extension)
      path = path_for(file, track, extension)
      return if path.file?

      failed_marker(path).delete if failed_marker(path).file?
      begin
        extract(file, track, extension, path)
      rescue Error, ToolRunner::Error => e
        FileUtils.mkdir_p(path.dirname)
        failed_marker(path).write(e.message.truncate(300))
        raise
      end
    end

    # Why this track couldn't be taken out, when it was tried within FAILED_FOR.
    sig { params(file: MediaFile, track: Tracks::Track, extension: String).returns(T.nilable(String)) }
    def self.failed(file, track, extension)
      marker = failed_marker(path_for(file, track, extension))
      return nil unless marker.file? && marker.mtime > FAILED_FOR.ago

      marker.read.presence || "couldn't be taken out of the file"
    end

    # A failure stands this long before a pick tries again.
    FAILED_FOR = T.let(1.hour, ActiveSupport::Duration)

    sig { params(path: Pathname).returns(Pathname) }
    def self.failed_marker(path) = path.sub_ext("#{path.extname}.failed")
    private_class_method :failed_marker

    # Every embedded track and font the file still lacks, as its part of the
    # one read over the file (Media::OnePass). Wanted for every file,
    # because the transcript and the fetch of missing languages follow it —
    # with nothing embedded, the step is done without a read.
    class Part < Media::OnePass::Part
      sig { params(file: MediaFile).void }
      def initialize(file)
        @file = file
        @outputs = T.let(Tracks.embedded(file).flat_map do |track|
          Extractor.extensions_for(track).reject { |extension| Extractor.path_for(file, track, extension).file? }.map do |extension|
            target = Extractor.path_for(file, track, extension)
            [ track, extension, target, target.sub_ext(".tmp#{target.extname}") ]
          end
        end, T::Array[[ Tracks::Track, String, Pathname, Pathname ]])
        # The tracks are out but the fonts aren't: a restore leaves them behind.
        @fonts = T.let(Extractor.font_attachments(file).any? && Extractor.fonts(file).empty?, T::Boolean)
      end

      sig { override.returns(AnalysisRun::Step) }
      def step = AnalysisRun::Step::Subtitles

      sig { override.returns(T::Boolean) }
      def missing? = @outputs.any? || @fonts

      sig { override.returns(T::Boolean) }
      def work? = missing?

      sig { override.void }
      def prepare
        FileUtils.mkdir_p(Extractor.root.join(@file.id.to_s))
        FileUtils.mkdir_p(Extractor.fonts_dir(@file)) if @fonts
      end

      sig { override.returns(T::Array[String]) }
      def input_args = @fonts ? Extractor.font_dump_args(@file) : []

      # Cues from the player's zero (the container's start time), the read
      # being in the file's own timestamps (-copyts).
      sig { override.returns(T::Array[T::Array[String]]) }
      def outputs
        start = Playback::FfmpegArgs.start_time(@file)
        zero = start.zero? ? [] : [ "-output_ts_offset", format("%.6f", -start) ]
        @outputs.map { |track, extension, _target, tmp| [ "-map", "0:#{track.stream_index}", *Extractor.codec_args(extension), *zero, tmp.to_s ] }
      end

      sig { override.params(result: T.nilable(ToolRunner::Result), keyframes_ms: T::Array[Integer]).void }
      def finish(result, keyframes_ms)
        @outputs.each { |_track, _extension, target, tmp| File.rename(tmp, target) if tmp.file? }
      end

      sig { override.void }
      def discard
        @outputs.each { |_track, _extension, _target, tmp| FileUtils.rm_f(tmp) }
      end
    end

    sig { params(track: Tracks::Track).returns(T::Array[String]) }
    def self.extensions_for(track)
      format = track.format
      case format
      when Tracks::Format::Vtt then %w[vtt]
      when Tracks::Format::Ass then %w[ass vtt]
      when Tracks::Format::Pgs then %w[sup]
      when Tracks::Format::Burn then []
      else T.absurd(format)
      end
    end

    # After a restore (FogBackup::Restorer): backups leave image tracks and
    # embedded fonts out — copies of what's in the file — so a file missing
    # either goes back through the background job, rather than the first
    # viewer to pick that track waiting on a whole-file read.
    sig { void }
    def self.requeue_missing!
      MediaFile.unscoped.playable.includes(:media_streams).find_each do |file|
        pgs_missing = Tracks.embedded(file).any? { |track| track.format == Tracks::Format::Pgs && !path_for(file, track, "sup").file? }
        fonts_missing = font_attachments(file).any? && fonts(file).empty?
        AnalyzeMediaFileJob.perform_later(file.id) if pgs_missing || fonts_missing
      end
    end

    # Fonts embedded in an MKV (ASS styling depends on them), for JASSUB.
    sig { params(file: MediaFile).returns(T::Array[Pathname]) }
    def self.fonts(file)
      directory = fonts_dir(file)
      directory.directory? ? directory.children.select(&:file?).sort : []
    end

    sig { params(file: MediaFile).returns(Pathname) }
    def self.fonts_dir(file) = root.join(file.id.to_s, "fonts")

    sig { params(file: MediaFile, track: Tracks::Track, extension: String, target: Pathname).void }
    def self.extract(file, track, extension, target)
      FileUtils.mkdir_p(target.dirname)
      tmp = target.sub_ext(".tmp#{target.extname}")
      sidecar = track.sidecar_path
      if track.generated
        tmp.write(transcript_vtt(file))
      elsif sidecar && ((extension == "ass" && track.format == Tracks::Format::Ass) || (extension == "sup"))
        FileUtils.cp(sidecar, tmp)
      else
        source = sidecar || file.path
        map = sidecar ? [] : [ "-map", "0:#{track.stream_index}" ]
        run(input_args(source) + map + codec_args(extension) + [ tmp.to_s ], paced: sidecar.nil? && audio?(file))
      end
      raise Error, "ffmpeg wrote nothing for #{track.id}" unless tmp.file?

      File.rename(tmp, target)
      extract_fonts(file) if track.format == Tracks::Format::Ass && sidecar.nil?
    end
    private_class_method :extract

    sig { params(file: MediaFile).returns(String) }
    def self.transcript_vtt(file)
      stamp = ->(seconds) { format("%02d:%02d:%06.3f", seconds.to_i / 3600, (seconds.to_i % 3600) / 60, seconds % 60) }
      cues = TranscriptLine.where(media_file_id: file.id).order(:start_seconds).pluck(:start_seconds, :end_seconds, :text)
        .map { |start, finish, text| "#{stamp.call(start)} --> #{stamp.call(finish)}\n#{text}" }
      "WEBVTT\n\n#{cues.join("\n\n")}\n"
    end
    private_class_method :transcript_vtt

    sig { params(file: MediaFile).returns(T::Array[T::Hash[String, T.untyped]]) }
    def self.font_attachments(file)
      Array(file.probe["streams"]).select do |stream|
        stream["codec_type"] == "attachment" && stream.dig("tags", "mimetype").to_s.match?(/font|truetype|opentype/i)
      end
    end

    # Input options that have ffmpeg write each embedded font into the
    # file's fonts directory as it opens the file.
    sig { params(file: MediaFile).returns(T::Array[String]) }
    def self.font_dump_args(file)
      directory = fonts_dir(file)
      font_attachments(file).flat_map do |stream|
        name = File.basename(stream.dig("tags", "filename").to_s).gsub(/[^\w.-]/, "_").presence || "font-#{stream['index']}"
        [ "-dump_attachment:#{stream['index']}", directory.join(name).to_s ]
      end
    end

    sig { params(file: MediaFile).void }
    def self.extract_fonts(file)
      args = font_dump_args(file)
      return if args.empty?

      FileUtils.mkdir_p(fonts_dir(file))
      # -dump_attachment wants an output; a zero-length null one does.
      ToolRunner.run([ "ffmpeg", "-hide_banner", "-v", "error", "-nostdin", "-y", *args, "-protocol_whitelist", "file",
        "-i", "file:#{file.path}", "-t", "0", "-f", "null", "-" ], timeout: 120)
    end
    private_class_method :extract_fonts

    sig { params(path: String).returns(T::Array[String]) }
    def self.input_args(path)
      [ "ffmpeg", "-hide_banner", "-v", "error", "-nostdin", "-nostats", "-y", "-progress", "pipe:1",
        "-protocol_whitelist", "file", "-i", "file:#{path}" ]
    end
    private_class_method :input_args

    sig { params(extension: String).returns(T::Array[String]) }
    def self.codec_args(extension)
      case extension
      when "vtt" then %w[-c:s webvtt -f webvtt]
      when "ass" then %w[-c:s copy -f ass]
      when "sup" then %w[-c:s copy -f sup]
      else raise Error, "unknown subtitle format #{extension}"
      end
    end

    sig { params(file: MediaFile).returns(T::Boolean) }
    def self.audio?(file) = file.media_streams.any? { |stream| stream.kind_enum == MediaStream::Kind::Audio }
    private_class_method :audio?

    sig { params(args: T::Array[String], paced: T::Boolean).void }
    def self.run(args, paced:)
      # Subtitles are sparse — minutes of film can pass without a cue — so a
      # video's read keeps time by the pace output. A sidecar (or a silent
      # file) is read without it: ffmpeg refuses an output with no streams.
      result = ToolRunner.run_advancing(paced ? args + Media::OnePass::PACE_OUTPUT : args, stall_timeout: STALL_TIMEOUT)
      raise Error, result.stderr.strip.lines.last.to_s.strip.presence || "ffmpeg exited #{result.status}" unless result.success?
    end
    private_class_method :run
  end
end
