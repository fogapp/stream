# typed: strict
# frozen_string_literal: true

module Playback
  # Adaptive bitrate (PROPOSAL §6.3): a repackaged stream also offers smaller
  # versions of itself — 1080p, 720p, 480p below the original — so a phone
  # on weak Wi-Fi can drop down instead of stalling. A smaller version is
  # only converted if a player actually asks for it; on the LAN nobody does,
  # and it costs nothing. Every version is cut at the same segment
  # boundaries as the original, so switching is seamless. Only for copied
  # video: a session already converting has no original quality to protect.
  module Variants
    extend T::Sig

    LADDER = T.let([ 1080, 720, 480 ].freeze, T::Array[Integer])

    class Variant < T::Struct
      extend T::Sig

      const :index, Integer
      # nil: the session's own video (copied).
      const :height, T.nilable(Integer)
      const :bandwidth, Integer
      const :codecs, T.nilable(String)
      const :resolution, T.nilable(String)

      sig { returns(T::Boolean) }
      def original? = index.zero?
    end

    # The session's own stream, as far as which version it is goes.
    ORIGINAL = Variant.new(index: 0, height: nil, bandwidth: 0, codecs: nil, resolution: nil)

    #
    # Only for an adaptive session (docs/PERF_PROPOSAL.md › P8): off the
    # household's network, or where a browser asked. On the LAN a player
    # that mistakes a slow transcoder for a slow network would drop to a
    # smaller version, and so start a second ffmpeg on a busy machine.
    sig { params(session: PlaybackSession).returns(T::Array[Variant]) }
    def self.for(session)
      return [ ORIGINAL ] unless session.adaptive

      file = session.media_file
      decision = session.stored_decision
      stream = file&.primary_video
      original = Variant.new(index: 0, height: nil, bandwidth: original_bandwidth(file), codecs: codecs(decision, stream),
        resolution: stream&.width && stream.height ? "#{stream.width}x#{stream.height}" : nil)
      return [ original ] unless decision.copy? && stream&.height

      source_height = T.must(stream.height)
      smaller = LADDER.select { |height| height < source_height - 60 }
      [ original ] + smaller.each_with_index.map do |height, i|
        width = stream.width ? (T.must(stream.width) * height / source_height.to_f / 2).round * 2 : nil
        audio = audio_codec(decision)
        Variant.new(index: i + 1, height: height, bandwidth: (FfmpegArgs.variant_bitrate(height) + 192) * 1000,
          codecs: [ "avc1.640028", audio ].compact.join(",").presence, resolution: width ? "#{width}x#{height}" : nil)
      end
    end

    # Version `index` of a session's stream, nil for one it doesn't have.
    # Every stream has its original, and what asks for it by index (the
    # transcoder, on every request) only needs to know it's the original:
    # it's answered without reading the file to build the ladder. Its
    # bandwidth and codecs are the master playlist's business (`for`).
    sig { params(session: PlaybackSession, index: Integer).returns(T.nilable(Variant)) }
    def self.find(session, index)
      return ORIGINAL if index.zero?

      self.for(session).find { |variant| variant.index == index }
    end

    sig { params(file: T.nilable(MediaFile)).returns(Integer) }
    def self.original_bandwidth(file)
      rate = file&.bit_rate.to_i
      rate.positive? ? (rate * 1.2).round : 20_000_000
    end

    # RFC 6381 codec strings, when the rows say enough; nil lets the player
    # find out from the init segment.
    sig { params(decision: StoredDecision, stream: T.nilable(MediaStream)).returns(T.nilable(String)) }
    def self.codecs(decision, stream)
      return nil unless decision.video && stream

      video_codec =
        if !decision.copy? then "avc1.640028"
        elsif stream.codec == "h264" then avc(stream)
        elsif stream.codec == "hevc" then stream.bit_depth.to_i > 8 ? "hvc1.2.4.L#{stream.level || 150}.B0" : "hvc1.1.6.L#{stream.level || 150}.90"
        end
      return nil if video_codec.nil?

      [ video_codec, audio_codec(decision) ].compact.join(",")
    end

    sig { params(stream: MediaStream).returns(T.nilable(String)) }
    def self.avc(stream)
      profile = { "Baseline" => "42", "Constrained Baseline" => "42", "Main" => "4d", "High" => "64" }[stream.profile.to_s]
      level = stream.level
      return nil if profile.nil? || level.nil?

      "avc1.#{profile}00#{format('%02x', level)}"
    end

    sig { params(decision: StoredDecision).returns(T.nilable(String)) }
    def self.audio_codec(decision)
      { "aac" => "mp4a.40.2", "ac3" => "ac-3", "eac3" => "ec-3", "flac" => "fLaC", "opus" => "Opus",
        "alac" => "alac" }[decision.audio_codec.to_s]
    end
  end
end
