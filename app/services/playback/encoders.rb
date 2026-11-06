# typed: strict
# frozen_string_literal: true

module Playback
  # Which video encoder this machine has (PROPOSAL §6.3): a startup probe
  # tries the hardware first and settles for software. The answer sets how
  # tall a conversion can be and how many can run at once.
  module Encoders
    extend T::Sig

    class Kind < T::Enum
      include ApplicationEnum
      enums do
        Software = new("software")
        # An Intel iGPU through the VA-API driver.
        Vaapi = new("vaapi")
        # Apple's media engine, on a Mac running a remote transcoder.
        Videotoolbox = new("videotoolbox")
      end

      sig { returns(T::Boolean) }
      def hardware? = self != Software
    end

    # One machine's encoder and HDR tone-mapper: this one's, or what a
    # remote transcoder reported about itself.
    class Profile < T::Struct
      extend T::Sig

      const :kind, Kind
      const :tonemap_filter, T.nilable(String)

      # An encoder of this kind on this machine, with the tone mapping its
      # ffmpeg has.
      sig { params(kind: Kind).returns(Profile) }
      def self.local(kind) = new(kind: kind, tonemap_filter: Encoders.tonemap_filter)

      # What ffmpeg is told before its input so the encoder has its device:
      # the render node for VA-API; for VideoToolbox, decoding on the media
      # engine too and a device for scale_vt (frames come back to memory
      # first, so a software filter before the upload still works, and a
      # codec the engine can't decode falls back to software by itself).
      sig { returns(T::Array[String]) }
      def device_args
        case kind
        when Kind::Vaapi then [ "-init_hw_device", "vaapi=va:#{RENDER_NODE}", "-filter_hw_device", "va" ]
        when Kind::Videotoolbox then %w[-hwaccel videotoolbox -init_hw_device videotoolbox=vt -filter_hw_device vt]
        else []
        end
      end

      # VideoToolbox tone-maps HDR to SDR in scale_vt as it scales, on the
      # media engine: 4.6x real time for 4K HDR10 on an M1, where zscale
      # and tonemap in software couldn't keep up (fog
      # docs/compute-nodes-proposal.md › 12.1).
      sig { returns(T::Boolean) }
      def hardware_tonemap? = kind == Kind::Videotoolbox

      # Whether HDR can be made SDR here at all.
      sig { returns(T::Boolean) }
      def tonemaps? = hardware_tonemap? || !tonemap_filter.nil?

      # How it tone-maps, as Settings and a transcoder's card say it.
      sig { returns(String) }
      def tonemap_name
        return "scale_vt" if hardware_tonemap?

        tonemap_filter.nil? ? "none" : tonemap_filter.to_s.split("=").first.to_s
      end
    end

    RENDER_NODE = "/dev/dri/renderD128"
    CACHE_KEY = "stream/encoder-probe/v2"
    # Longer than the transcoder's hourly probe, so the answer never lapses
    # while it's running.
    PROBE_LIFETIME = T.let(3.hours, ActiveSupport::Duration)

    # What the transcoder found. Web never probes (docs/PERF_PROPOSAL.md ›
    # P5): an ffmpeg test encode has no place in a press of Play, and the
    # transcoder is where the encoder lives anyway. Software until it has.
    sig { returns(Kind) }
    def self.kind
      Kind.try_deserialize(Rails.cache.read(CACHE_KEY).to_s) || Kind::Software
    end

    # Probe and share the answer: the transcoder at start and every hour.
    sig { returns(Kind) }
    def self.probe!
      found = probe
      Rails.cache.write(CACHE_KEY, found.serialize, expires_in: PROBE_LIFETIME)
      found
    end

    sig { returns(Integer) }
    def self.max_height = max_height_for(kind)

    sig { params(kind: Kind).returns(Integer) }
    def self.max_height_for(kind) = kind.hardware? ? 2160 : Decision::SOFTWARE_MAX_HEIGHT

    # Simultaneous video conversions. Measured in Phase 0 (spikes.md › C):
    # with AVX2, 4 vCPU convert HEVC HDR → SDR at 4.6× real time, and each
    # run is throttled to 2× after its first 30 s, so two fit. Without AVX2
    # (a VM's default virtual CPU, often) x264 is several times slower: one.
    # Three on the iGPU.
    sig { returns(Integer) }
    def self.default_cap
      return 3 unless kind == Kind::Software

      avx2? ? 2 : 1
    end

    # Whether the CPU the transcoder runs on has AVX2, from the kernel's own
    # flag list. False wherever there isn't one to read (a Mac laptop).
    sig { returns(T::Boolean) }
    def self.avx2?
      return @avx2 unless @avx2.nil?

      @avx2 = T.let(File.readable?("/proc/cpuinfo") && File.foreach("/proc/cpuinfo").any? { |line| line.start_with?("flags") && line.split.include?("avx2") },
        T.nilable(T::Boolean))
      @avx2 || false
    end

    sig { returns(Integer) }
    def self.cap = AppSetting.cached.max_video_transcodes || default_cap

    # One real frame through the hardware encoder: a render node that exists
    # but can't encode (wrong driver, no permission) must not be chosen.
    sig { returns(Kind) }
    def self.probe
      return Kind::Software unless File.exist?(RENDER_NODE)

      result = ToolRunner.run(%W[ffmpeg -hide_banner -v error -init_hw_device vaapi=va:#{RENDER_NODE} -filter_hw_device va
        -f lavfi -i testsrc2=size=320x240:duration=0.1 -vf format=nv12,hwupload -c:v h264_vaapi -frames:v 1 -f null -],
        timeout: 20)
      result.success? ? Kind::Vaapi : Kind::Software
    rescue ToolRunner::Error
      Kind::Software
    end

    # jellyfin-ffmpeg's SIMD tone-mapper when present (production), the
    # zscale chain otherwise (a stock ffmpeg on a laptop).
    sig { returns(T.nilable(String)) }
    def self.tonemap_filter
      @tonemap_filter ||= T.let(
        begin
          listing = ToolRunner.run(%w[ffmpeg -hide_banner -filters], timeout: 20).stdout
          tonemap_for(listing.scan(/^[ \t]*\S+[ \t]+(\w+)[ \t]/).flatten) || ""
        end,
        T.nilable(String)
      )
      @tonemap_filter.presence
    end

    # The tone-mapping chain for an ffmpeg with these filters.
    sig { params(filters: T::Array[String]).returns(T.nilable(String)) }
    def self.tonemap_for(filters)
      if filters.include?("tonemapx")
        "tonemapx=tonemap=bt2390:desat=0:peak=100:t=bt709:m=bt709:p=bt709:format=yuv420p"
      elsif filters.include?("zscale") && filters.include?("tonemap")
        "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0," \
          "zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
      end
    end
  end
end
