# typed: strict
# frozen_string_literal: true

module Playback
  # The video encoder's end of a conversion, for each encoder this machine
  # can have (Encoders::Kind): the filters that upload, scale and set the
  # pixel format, and the codec's own arguments. One table for both kinds
  # of conversion — a session's run (FfmpegArgs, LiveArgs), which has to
  # keep ahead of a viewer, and an optimized version (OptimizeArgs), which
  # has all night and so takes the slower presets.
  module EncoderArgs
    extend T::Sig

    class Quality < T::Enum
      enums do
        # A session's run or a live relay.
        Live = new("live")
        # An optimized version (PROPOSAL §5.5).
        Optimize = new("optimize")
      end
    end

    class Encoding < T::Struct
      # After whatever made the picture (trimmed, deinterlaced, tone-mapped).
      const :filters, T::Array[String]
      const :codec, T::Array[String]
    end

    # tonemap: VideoToolbox's scale_vt makes HDR BT.709 SDR as it scales
    # (Encoders::Profile#hardware_tonemap?); the other encoders take a
    # software tone map in the picture's filters instead.
    sig { params(kind: Encoders::Kind, height: Integer, keyframes: String, quality: Quality, tonemap: T::Boolean).returns(Encoding) }
    def self.for(kind, height:, keyframes:, quality:, tonemap: false)
      ceiling = FfmpegArgs.bitrate_for(height)
      buffer = [ "-maxrate", "#{ceiling}k", "-bufsize", "#{ceiling * 2}k" ]
      case kind
      when Encoders::Kind::Vaapi
        filters = [ "format=nv12", "hwupload", "scale_vaapi=w=-2:h=#{height}" ]
        codec = case quality
        when Quality::Live then %w[-c:v h264_vaapi -qp 22]
        when Quality::Optimize then %w[-c:v h264_vaapi -qp 20 -profile:v high]
        else T.absurd(quality)
        end
      when Encoders::Kind::Software
        case quality
        when Quality::Live
          filters = [ "scale=-2:#{height}:flags=bicubic", "format=yuv420p" ]
          codec = %w[-c:v libx264 -preset veryfast -crf 21] + buffer + %w[-profile:v high -sc_threshold 0]
        when Quality::Optimize
          filters = [ "scale=-2:#{height}:flags=lanczos", "format=yuv420p" ]
          codec = %w[-c:v libx264 -preset slow -crf 20 -profile:v high] + buffer
        else T.absurd(quality)
        end
      when Encoders::Kind::Videotoolbox
        filters = [ "hwupload", FfmpegArgs.scale_vt(height, tonemap) ]
        codec = case quality
        when Quality::Live then %w[-c:v h264_videotoolbox -realtime 1 -profile:v high] + [ "-b:v", "#{ceiling / 2}k" ]
        when Quality::Optimize then %w[-c:v h264_videotoolbox -profile:v high] + [ "-b:v", "#{ceiling * 6 / 10}k" ]
        else T.absurd(quality)
        end
        codec += buffer
      else T.absurd(kind)
      end
      Encoding.new(filters: filters, codec: codec + [ "-force_key_frames", keyframes ])
    end
  end
end
