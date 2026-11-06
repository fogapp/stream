# typed: strict
# frozen_string_literal: true

module Media
  # ffprobe, once per file, at scan time (CLAUDE.md invariant 4). Returns the
  # container facts and every stream normalized into MediaStream columns;
  # the raw JSON is kept on the file for the analysis page.
  module Probe
    extend T::Sig

    class Error < StandardError; end

    # A NAS read of a file's header and index: seconds normally, but a cold
    # disk or a busy share can take a while. Past this the file is broken or
    # the share is.
    TIMEOUT = 120

    # A file ffprobe couldn't make sense of: no streams, or no index to
    # find them by (MP4 with its moov never written).
    DAMAGED = /moov atom not found|invalid data found/i
    # A truncated file — a copy still in progress, a download cut short —
    # still has a readable header, so ffprobe exits 0 and lists its streams.
    # These lines on stderr are the only sign. It plays up to where it ends,
    # as it does in Plex and Jellyfin, so it's kept, with a warning;
    # it used to be Broken, and unplayable.
    TRUNCATED = /ended prematurely|truncat/i
    # A stream ffprobe found but couldn't read the parameters of within its
    # first look: a TS whose sound starts late, say. Probed again, further.
    UNREAD = /could not find codec parameters/i

    # How far ffprobe reads to find every stream's parameters: the default
    # 5 MB / 5 s missed sound that starts late in a TS and left channels or
    # pixel format empty; a second look goes further still.
    PROBE_SIZE = "50M"
    DEEP_PROBE_SIZE = "200M"

    class Result < T::Struct
      const :container, T.nilable(String)
      const :duration_seconds, T.nilable(Float)
      const :bit_rate, T.nilable(Integer)
      const :streams, T::Array[T::Hash[Symbol, T.untyped]]
      const :chapters, T::Array[T::Hash[String, T.untyped]], default: []
      const :raw, T::Hash[String, T.untyped]
      # What's wrong with a file that still plays (truncated), for Needs attention.
      const :warning, T.nilable(String), default: nil
    end

    sig { params(path: String).returns(Result) }
    def self.run(path)
      result = ffprobe(path, PROBE_SIZE)
      raw = parse(result.stdout)
      streams = Array(raw["streams"])
      # A stream left half-read: look again, further in.
      if result.success? && (result.stderr.match?(UNREAD) || streams.any? { |stream| unread?(stream) })
        deeper = ffprobe(path, DEEP_PROBE_SIZE)
        deeper_raw = parse(deeper.stdout)
        if deeper.success? && Array(deeper_raw["streams"]).any?
          result = deeper
          raw = deeper_raw
          streams = Array(raw["streams"])
        end
      end
      damage = result.stderr.lines.find { |line| line.match?(DAMAGED) }
      if !result.success? || streams.empty? || damage
        message = (damage || result.stderr.lines.first).to_s.sub(/\A\[[^\]]*\]\s*/, "").strip.presence
        raise Error, message || "no streams found"
      end
      truncated = result.stderr.lines.find { |line| line.match?(TRUNCATED) }&.sub(/\A\[[^\]]*\]\s*/, "")&.strip

      streams = with_frame_color(path, streams)
      format = raw.fetch("format", {})
      Result.new(
        container: format["format_name"],
        duration_seconds: float(format["duration"]),
        bit_rate: integer(format["bit_rate"]),
        streams: streams.filter_map { |stream| normalize(stream) },
        chapters: chapters(raw),
        raw: raw,
        warning: truncated && "The file ends early (#{truncated.truncate(120)}): it plays up to there"
      )
    end

    sig { params(path: String, size: String).returns(ToolRunner::Result) }
    def self.ffprobe(path, size)
      ToolRunner.run([
        "ffprobe", "-v", "warning", "-protocol_whitelist", "file", "-print_format", "json",
        "-probesize", size, "-analyzeduration", size,
        # file: pins the protocol, so no name is ever read as a URL scheme.
        "-show_format", "-show_streams", "-show_chapters", "-i", "file:#{path}"
      ], timeout: TIMEOUT)
    end
    private_class_method :ffprobe

    # A picture with no pixel format, or sound with no channels or rate:
    # its parameters weren't found in the first look.
    sig { params(stream: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def self.unread?(stream)
      case stream["codec_type"]
      when "video" then stream.dig("disposition", "attached_pic") != 1 && stream["pix_fmt"].blank?
      when "audio" then stream["channels"].to_i.zero? || stream["sample_rate"].to_i.zero?
      else false
      end
    end
    private_class_method :unread?

    # ffprobe 8+ reports colour metadata only at the frame level for some
    # files (an MKV with no Colour element: the values live in the HEVC
    # VUI). Missing it would read HDR10 as SDR, and SDR screens would get
    # washed-out video instead of a tone-mapped one. So for 10-bit+ video
    # with no transfer at the stream level, read the first frame's.
    sig do
      params(path: String, streams: T::Array[T::Hash[String, T.untyped]]).returns(T::Array[T::Hash[String, T.untyped]])
    end
    def self.with_frame_color(path, streams)
      video = streams.find { |stream| stream["codec_type"] == "video" && stream.dig("disposition", "attached_pic") != 1 }
      return streams if video.nil? || video["color_transfer"].present?
      return streams unless video["pix_fmt"].to_s.match?(/p1[0-6](le|be)\z/)

      result = ToolRunner.run([
        "ffprobe", "-v", "error", "-protocol_whitelist", "file", "-select_streams", "v:0", "-read_intervals", "%+#1",
        "-show_frames", "-show_entries", "frame=color_transfer,color_primaries:frame_side_data=side_data_type",
        "-print_format", "json", "-i", "file:#{path}"
      ], timeout: TIMEOUT)
      frame = Array(parse(result.stdout)["frames"]).first
      return streams if frame.nil?

      video["color_transfer"] ||= frame["color_transfer"]
      video["color_primaries"] ||= frame["color_primaries"]
      video["side_data_list"] = Array(video["side_data_list"]) + Array(frame["side_data_list"])
      streams
    rescue ToolRunner::Error
      streams
    end
    private_class_method :with_frame_color

    # Container chapters as [{start, end, title}] in seconds. A single
    # chapter spanning the file says nothing, so it's dropped.
    sig { params(raw: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[String, T.untyped]]) }
    def self.chapters(raw)
      list = Array(raw["chapters"]).filter_map do |chapter|
        start = float(chapter["start_time"])
        finish = float(chapter["end_time"])
        next nil if start.nil? || finish.nil? || finish <= start

        { "start" => start.round(3), "end" => finish.round(3), "title" => chapter.dig("tags", "title").presence }
      end
      list.size > 1 ? list : []
    end
    private_class_method :chapters

    sig { params(stdout: String).returns(T::Hash[String, T.untyped]) }
    def self.parse(stdout)
      parsed = JSON.parse(stdout.presence || "{}")
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    KINDS = T.let({
      "video" => MediaStream::Kind::Video, "audio" => MediaStream::Kind::Audio,
      "subtitle" => MediaStream::Kind::Subtitle, "attachment" => MediaStream::Kind::Attachment,
      "data" => MediaStream::Kind::Data
    }.freeze, T::Hash[String, MediaStream::Kind])

    # ffprobe's streams as MediaStream columns — a file's here, a live
    # stream's from LiveStreams::Prober.
    sig { params(raw: T::Hash[String, T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.streams_from(raw) = Array(raw["streams"]).filter_map { |stream| normalize(stream) }

    # Cover art rides in MKV/MP4 as a one-frame "video" stream; it is an
    # attachment for every purpose Stream has.
    sig { params(stream: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def self.normalize(stream)
      kind = KINDS[stream["codec_type"].to_s]
      return nil if kind.nil?

      disposition = stream.fetch("disposition", {})
      kind = MediaStream::Kind::Attachment if kind == MediaStream::Kind::Video && disposition["attached_pic"] == 1
      tags = stream.fetch("tags", {})
      dovi = Array(stream["side_data_list"]).find { |side| side["side_data_type"].to_s.include?("DOVI") }

      {
        index: stream.fetch("index"),
        kind: kind.serialize,
        codec: stream["codec_name"],
        profile: stream["profile"].presence,
        level: integer(stream["level"])&.then { |level| level.negative? ? nil : level },
        bit_depth: bit_depth(stream),
        width: integer(stream["width"]),
        height: integer(stream["height"]),
        frame_rate: kind == MediaStream::Kind::Video ? rational(stream["avg_frame_rate"] || stream["r_frame_rate"]) : nil,
        pixel_format: stream["pix_fmt"],
        color_primaries: stream["color_primaries"],
        color_transfer: stream["color_transfer"],
        hdr_format: kind == MediaStream::Kind::Video ? hdr_format(stream, dovi)&.serialize : nil,
        dolby_vision_profile: dovi ? integer(dovi["dv_profile"]) : nil,
        channels: integer(stream["channels"]),
        channel_layout: stream["channel_layout"],
        language: normalize_language(tags["language"]),
        title: tags["title"].presence,
        bit_rate: integer(stream["bit_rate"] || tags["BPS"]),
        default: disposition["default"] == 1,
        forced: disposition["forced"] == 1,
        # What decisions need that the
        # probe saw anyway.
        start_time: float(stream["start_time"]),
        field_order: stream["field_order"].presence,
        sample_aspect_ratio: stream["sample_aspect_ratio"].presence,
        rotation: rotation(stream),
        sample_rate: integer(stream["sample_rate"]),
        codec_tag: stream["codec_tag_string"].presence,
        chroma: kind == MediaStream::Kind::Video ? chroma(stream["pix_fmt"]) : nil,
        refs: integer(stream["refs"]),
        has_b_frames: integer(stream["has_b_frames"]),
        comment: disposition["comment"] == 1,
        hearing_impaired: disposition["hearing_impaired"] == 1,
        visual_impaired: disposition["visual_impaired"] == 1
      }
    end
    private_class_method :normalize

    # The chroma subsampling a pixel format has: "420", "422", "444", "411",
    # or "400" for greyscale. Decoders in browsers take only 4:2:0.
    sig { params(pixel_format: T.nilable(String)).returns(T.nilable(String)) }
    def self.chroma(pixel_format)
      format = pixel_format.to_s
      return nil if format.empty?
      return "444" if format.include?("444") || format.start_with?("gbr", "rgb", "bgr")
      return "422" if format.include?("422") || %w[yuyv422 uyvy422 nv16 p210le].include?(format)
      return "411" if format.include?("411")
      return "400" if format.start_with?("gray")

      "420"
    end

    # Degrees a picture is to be turned for display: the display matrix's,
    # or an old-style rotate tag.
    sig { params(stream: T::Hash[String, T.untyped]).returns(T.nilable(Integer)) }
    def self.rotation(stream)
      matrix = Array(stream["side_data_list"]).find { |side| side.key?("rotation") }
      return float(matrix["rotation"])&.round if matrix

      integer(stream.dig("tags", "rotate"))
    end
    private_class_method :rotation

    sig do
      params(stream: T::Hash[String, T.untyped], dovi: T.nilable(T::Hash[String, T.untyped]))
        .returns(T.nilable(MediaStream::HdrFormat))
    end
    def self.hdr_format(stream, dovi)
      return MediaStream::HdrFormat::DolbyVision if dovi

      case stream["color_transfer"]
      when "smpte2084"
        hdr10_plus = Array(stream["side_data_list"]).any? { |side| side["side_data_type"].to_s.include?("2094-40") }
        hdr10_plus ? MediaStream::HdrFormat::Hdr10Plus : MediaStream::HdrFormat::Hdr10
      when "arib-std-b67"
        MediaStream::HdrFormat::Hlg
      end
    end
    private_class_method :hdr_format

    sig { params(stream: T::Hash[String, T.untyped]).returns(T.nilable(Integer)) }
    def self.bit_depth(stream)
      explicit = integer(stream["bits_per_raw_sample"])
      return explicit if explicit&.positive?

      pixel_format = stream["pix_fmt"].to_s
      return nil if pixel_format.empty?

      pixel_format[/p(\d+)(le|be)\z/, 1]&.to_i || 8
    end
    private_class_method :bit_depth

    # "und" and blank mean nobody said; that is nil, not a language.
    sig { params(raw: T.untyped).returns(T.nilable(String)) }
    def self.normalize_language(raw)
      value = raw.to_s.strip.downcase
      value.empty? || value == "und" ? nil : value
    end
    private_class_method :normalize_language

    sig { params(raw: T.untyped).returns(T.nilable(Float)) }
    def self.rational(raw)
      numerator, denominator = raw.to_s.split("/").map(&:to_f)
      return nil if numerator.nil? || denominator.nil? || denominator.zero? || numerator.zero?

      (numerator / denominator).round(3)
    end
    private_class_method :rational

    sig { params(raw: T.untyped).returns(T.nilable(Float)) }
    def self.float(raw)
      value = T.let(Float(raw.to_s, exception: false), T.nilable(Float))
      value&.finite? ? value : nil
    end
    private_class_method :float

    sig { params(raw: T.untyped).returns(T.nilable(Integer)) }
    def self.integer(raw) = Integer(raw.to_s, exception: false)
    private_class_method :integer
  end
end
