# typed: strict
# frozen_string_literal: true

module Media
  # Renders a file's seek-bar thumbnails (PROPOSAL §5.5) as its part of the
  # one read over the file (OnePass). Decodes only keyframes — a frame
  # every ten seconds doesn't need the frames between — so a two-hour film
  # takes seconds of CPU, not minutes. HDR sources are tone-mapped so the
  # thumbnails don't come out grey.
  module TrickplayBuilder
    extend T::Sig

    INTERVAL = 10
    WIDTH = 320
    COLUMNS = 10
    ROWS = 10

    # Ten seconds apart for anything film-length; a short clip (a home video,
    # a YouTube Short) gets about ten thumbnails, at least a second apart.
    sig { params(duration: Float).returns(Integer) }
    def self.interval_for(duration)
      return INTERVAL if duration >= 60

      [ (duration / 10).ceil, 1 ].max
    end

    class Part < OnePass::Part
      sig { params(file: MediaFile, video: MediaStream).void }
      def initialize(file, video)
        @file = file
        @video = video
        @trickplay = T.let(Trickplay.find_or_initialize_by(media_file: file), Trickplay)
        @version = T.let(@trickplay.version + 1, Integer)
        @target = T.let(@trickplay.directory.join(@version.to_s), Pathname)
        @interval = T.let(TrickplayBuilder.interval_for(file.duration_seconds.to_f), Integer)
      end

      sig { override.returns(AnalysisRun::Step) }
      def step = AnalysisRun::Step::Trickplay

      # Never rendered, or a restore left the sheets out (Trickplay.requeue_missing!).
      sig { override.returns(T::Boolean) }
      def missing? = @trickplay.new_record? || @trickplay.version.zero? || !@trickplay.sheet(0).file?

      sig { override.returns(T::Boolean) }
      def decodes_video? = true

      sig { override.void }
      def prepare
        FileUtils.mkdir_p(@target)
      end

      # One frame per interval from the player's zero (the container's start
      # time, under -copyts); a clip with a single keyframe still gets its one
      # (eof_action=pass), where fps alone would wait for a next frame that
      # never comes and write nothing.
      sig { override.params(input: String).returns(T.nilable(String)) }
      def video_chain(input)
        fps = [ "fps=1/#{@interval}", "eof_action=pass" ]
        start = Playback::FfmpegArgs.start_time(@file)
        fps << format("start_time=%.6f", start) unless start.zero?
        filters = [ fps.join(":"), "scale=#{WIDTH}:#{height}" ]
        tonemap = Playback::Encoders.tonemap_filter
        filters << tonemap if @video.hdr_format.present? && tonemap
        filters << "format=yuv420p" << "tile=#{COLUMNS}x#{ROWS}"
        "#{input}#{filters.join(',')}[sheets]"
      end

      sig { override.returns(T::Array[T::Array[String]]) }
      def outputs
        [ [ "-map", "[sheets]", "-c:v", "libwebp", "-quality", "60", "-f", "image2", "-start_number", "0", @target.join("sheet-%d.webp").to_s ] ]
      end

      sig { override.params(result: T.nilable(ToolRunner::Result), keyframes_ms: T::Array[Integer]).void }
      def finish(result, keyframes_ms)
        sheets = @target.glob("sheet-*.webp").size
        raise ToolRunner::Error, "ffmpeg wrote no thumbnails" unless sheets.positive?

        previous = @trickplay.version
        thumbnails = [ (@file.duration_seconds.to_f / @interval).ceil, sheets * COLUMNS * ROWS ].min
        @trickplay.update!(version: @version, interval_seconds: @interval, tile_width: WIDTH, tile_height: height,
          columns: COLUMNS, rows: ROWS, sheet_count: sheets, thumbnail_count: [ thumbnails, 1 ].max)
        FileUtils.rm_rf(@trickplay.directory.join(previous.to_s)) if previous.positive?
      end

      sig { override.void }
      def discard
        FileUtils.rm_rf(@target)
      end

      private

      sig { returns(Integer) }
      def height = ((WIDTH * @video.height.to_f / @video.width.to_f) / 2).round * 2
    end
  end
end
