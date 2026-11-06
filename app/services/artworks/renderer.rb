# typed: strict
# frozen_string_literal: true

module Artworks
  # Renders one source image (or a frame of a video) into WebP at each of
  # its kind's widths, plus a tiny blurred placeholder and an average
  # colour (PROPOSAL §5.5). ffmpeg does it: it's already in every image
  # Stream runs in, speaks every format TMDB serves, and keeps alpha for logos.
  module Renderer
    extend T::Sig

    class Error < StandardError; end

    PLACEHOLDER_WIDTH = 24
    TIMEOUT = 60
    # Seeking into a video on a NAS (or through a file with no index) can
    # take far longer than resizing a still, so the one decode gets longer.
    FRAME_TIMEOUT = 300

    class Result < T::Struct
      const :width, Integer
      const :height, Integer
      const :widths, T::Array[Integer]
      const :placeholder, String
      const :color, String
    end

    sig do
      params(source: String, into: Pathname, widths: T::Array[Integer], alpha: T::Boolean,
        seek_seconds: T.nilable(Float)).returns(Result)
    end
    def self.render(source, into:, widths:, alpha: false, seek_seconds: nil)
      return render_still(source, into:, widths:, alpha:) if seek_seconds.nil?

      # A video frame is decoded once, then every size comes from the still,
      # rather than seeking into the video again for each one.
      Tempfile.create([ "frame", ".png" ]) do |frame|
        grab_frame(source, seek_seconds, frame.path)
        render_still(frame.path, into:, widths:, alpha:)
      end
    end

    sig { params(source: String, into: Pathname, widths: T::Array[Integer], alpha: T::Boolean).returns(Result) }
    def self.render_still(source, into:, widths:, alpha:)
      FileUtils.mkdir_p(into)
      input = input_args(source)
      width, height = dimensions(source)
      # Never upscale: a 500 px logo stays 500 px wide at the 1920 slot.
      rendered = widths.map { |target| [ target, [ target, width ].min ] }.uniq(&:last)
      rendered.each do |slot, actual|
        run(input + [ "-vf", "scale=#{actual}:-2:flags=lanczos", *encoder(alpha, quality: 82), into.join("#{slot}.webp").to_s ])
      end
      # Slots that would have needed upscaling point at the largest real one.
      largest = rendered.max_by(&:last)
      (widths - rendered.map(&:first)).each do |slot|
        FileUtils.cp(into.join("#{largest&.first}.webp"), into.join("#{slot}.webp"))
      end

      Result.new(width: width, height: height, widths: widths, placeholder: placeholder(input, alpha),
        color: average_color(input))
    end

    private_class_method :render_still

    sig { params(source: String).returns(T::Array[String]) }
    def self.input_args(source)
      %w[ffmpeg -hide_banner -nostdin -v error -y -protocol_whitelist file] + [ "-i", "file:#{source}", "-frames:v", "1" ]
    end
    private_class_method :input_args

    # The first real video stream (0:V skips cover art attached to the file).
    sig { params(source: String, seek_seconds: Float, into: String).void }
    def self.grab_frame(source, seek_seconds, into)
      run(%w[ffmpeg -hide_banner -nostdin -v error -y -protocol_whitelist file] +
        [ "-ss", format("%.3f", seek_seconds), "-i", "file:#{source}", "-map", "0:V:0", "-frames:v", "1",
          "-c:v", "png", "-pix_fmt", "rgb24", into ], timeout: FRAME_TIMEOUT)
    end
    private_class_method :grab_frame

    sig { params(alpha: T::Boolean, quality: Integer).returns(T::Array[String]) }
    def self.encoder(alpha, quality:)
      [ "-c:v", "libwebp", "-quality", quality.to_s, "-pix_fmt", alpha ? "yuva420p" : "yuv420p" ]
    end
    private_class_method :encoder

    sig { params(input: T::Array[String], alpha: T::Boolean).returns(String) }
    def self.placeholder(input, alpha)
      Tempfile.create([ "placeholder", ".webp" ]) do |file|
        run(input + [ "-vf", "scale=#{PLACEHOLDER_WIDTH}:-2", *encoder(alpha, quality: 30), file.path ])
        "data:image/webp;base64,#{Base64.strict_encode64(File.binread(file.path))}"
      end
    end
    private_class_method :placeholder

    sig { params(input: T::Array[String]).returns(String) }
    def self.average_color(input)
      result = ToolRunner.run(input + [ "-vf", "scale=1:1:flags=area", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1" ],
        timeout: TIMEOUT)
      red, green, blue = result.stdout.bytes.first(3)
      return "#1a1a1a" if red.nil? || green.nil? || blue.nil?

      format("#%<r>02x%<g>02x%<b>02x", r: red, g: green, b: blue)
    end
    private_class_method :average_color

    sig { params(source: String).returns([ Integer, Integer ]) }
    def self.dimensions(source)
      result = ToolRunner.run([ "ffprobe", "-v", "error", "-protocol_whitelist", "file", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0", "-i", "file:#{source}" ], timeout: TIMEOUT)
      width, height = result.stdout.strip.lines.first.to_s.split(",").map(&:to_i)
      raise Error, "Couldn't read an image from #{File.basename(source)}" if width.to_i.zero? || height.to_i.zero?

      [ width.to_i, height.to_i ]
    end
    private_class_method :dimensions

    sig { params(argv: T::Array[String], timeout: Integer).void }
    def self.run(argv, timeout: TIMEOUT)
      result = ToolRunner.run(argv, timeout: timeout)
      return if result.success?

      raise Error, result.stderr.strip.lines.last.to_s.strip.presence || "ffmpeg exited #{result.status}"
    end
    private_class_method :run
  end
end
