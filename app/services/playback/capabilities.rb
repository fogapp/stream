# typed: strict
# frozen_string_literal: true

module Playback
  # What a client can decode, as it reported it (PROPOSAL §6.1). Built in the
  # browser from MediaSource.isTypeSupported, canPlayType and
  # mediaCapabilities; parsed here with a conservative default for anything
  # missing, so a sparse or old profile errs toward converting, never toward
  # a black screen.
  class Capabilities < T::Struct
    extend T::Sig

    class Hls < T::Enum
      include ApplicationEnum
      enums do
        Native = new("native")
        Mse = new("mse")
        Unsupported = new("none")
      end
    end

    # Video decoder keys: codec plus the variant that decides decodability.
    VIDEO_KEYS = T.let(%w[h264 h264_10 hevc hevc_10 av1 av1_10 vp9 vp9_10 vp8].freeze, T::Array[String])
    AUDIO_KEYS = T.let(%w[aac mp3 opus flac vorbis alac ac3 eac3 dts truehd].freeze, T::Array[String])
    HDR_KEYS = T.let(%w[hdr10 hdr10_plus hlg dolby_vision].freeze, T::Array[String])
    CONTAINER_KEYS = T.let(%w[mp4 webm].freeze, T::Array[String])

    # What every browser Stream supports has decoded for a decade.
    BASELINE = T.let({
      "hls" => "mse", "containers" => %w[mp4], "video" => %w[h264], "audio" => %w[aac mp3],
      "max_audio_channels" => 2, "hdr" => [], "max_height" => 1080
    }.freeze, T::Hash[String, T.untyped])

    const :hls, Hls
    const :containers, T::Array[String]
    const :video, T::Array[String]
    const :audio, T::Array[String]
    const :max_audio_channels, Integer
    const :hdr, T::Array[String]
    # How tall a conversion is made for this screen. A copy plays at any
    # height the decoder takes smoothly (smooth), and the browser scales it.
    const :max_height, Integer
    # What the streaming path decodes — MediaSource for hls.js, the
    # browser's own player for native HLS — which isn't always what a file
    # opened directly does. The direct
    # path's lists when the client didn't say.
    const :stream_video, T::Array[String]
    const :stream_audio, T::Array[String]
    # The highest level each codec decodes at, in ffprobe's numbering
    # (H.264 51 = 5.1, HEVC 153 = 5.1, AV1 13 = 5.1); a codec not listed
    # isn't limited.
    const :levels, T::Hash[String, Integer], default: {}
    # The tallest picture each codec decodes smoothly (mediaCapabilities);
    # a codec not listed isn't limited.
    const :smooth, T::Hash[String, Integer], default: {}

    sig { params(raw: T.untyped).returns(Capabilities) }
    def self.from_json(raw)
      data = raw.is_a?(Hash) ? raw.stringify_keys : {}
      data = BASELINE.merge(data.compact)
      video = list(data["video"], VIDEO_KEYS)
      audio = list(data["audio"], AUDIO_KEYS)
      new(
        hls: Hls.try_deserialize(data["hls"].to_s) || Hls::Mse,
        containers: list(data["containers"], CONTAINER_KEYS),
        video: video,
        audio: audio,
        max_audio_channels: data["max_audio_channels"].to_i.clamp(1, 8),
        hdr: list(data["hdr"], HDR_KEYS),
        max_height: data["max_height"].to_i.clamp(240, 4320),
        stream_video: data.key?("stream_video") ? list(data["stream_video"], VIDEO_KEYS) : video,
        stream_audio: data.key?("stream_audio") ? list(data["stream_audio"], AUDIO_KEYS) : audio,
        levels: numbers(data["levels"], 1, 255),
        smooth: numbers(data["smooth"], 240, 4320)
      )
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def to_json_hash
      { "hls" => hls.serialize, "containers" => containers, "video" => video, "audio" => audio,
        "max_audio_channels" => max_audio_channels, "hdr" => hdr, "max_height" => max_height,
        "stream_video" => stream_video, "stream_audio" => stream_audio, "levels" => levels, "smooth" => smooth }
    end

    # A copy of these capabilities with some taken away (Quirks).
    sig { params(video: T::Array[String], audio: T::Array[String], hdr: T::Array[String]).returns(Capabilities) }
    def without(video: [], audio: [], hdr: [])
      Capabilities.new(**serialize.symbolize_keys.except(:hls).merge(
        hls: self.hls, video: self.video - video, stream_video: stream_video - video,
        audio: self.audio - audio, stream_audio: stream_audio - audio, hdr: self.hdr - hdr
      ))
    end

    sig { params(value: T.untyped, allowed: T::Array[String]).returns(T::Array[String]) }
    def self.list(value, allowed)
      Array(value).map(&:to_s) & allowed
    end
    private_class_method :list

    # A codec-keyed map of numbers, sane ones only.
    sig { params(value: T.untyped, low: Integer, high: Integer).returns(T::Hash[String, Integer]) }
    def self.numbers(value, low, high)
      return {} unless value.respond_to?(:to_h)

      value.to_h.each_with_object({}) do |(codec, number), out|
        key = codec.to_s
        next unless VIDEO_KEYS.include?(key) || %w[h264 hevc av1 vp9].include?(key)

        amount = T.let(Integer(number.to_s, exception: false), T.nilable(Integer))
        out[key] = amount if amount&.between?(low, high)
      end
    end
    private_class_method :numbers
  end
end
