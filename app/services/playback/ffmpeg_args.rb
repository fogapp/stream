# typed: strict
# frozen_string_literal: true

module Playback
  # The ffmpeg command for one run of one session (PROPOSAL §6.3,
  # spikes.md › B). Every run, wherever it starts, writes the same
  # fragments: cut at every keyframe, timestamps kept absolute (-copyts,
  # frag_discont), so fragments from different runs join seamlessly and
  # share one init segment. It numbers them from the GOP it was started
  # for, into a directory of its own; which GOP each really is is read
  # back from the fragment when it's published (Publisher).
  module FfmpegArgs
    extend T::Sig


    # Where ffmpeg reads the original: the file itself, or — on a remote
    # transcoder — a signed URL Stream serves it from, or a live stream's own
    # address (PROPOSAL §7.8). Only those protocols are allowed (CLAUDE.md
    # invariant 6), and never `file` for a URL: a playlist from the web
    # can't point ffmpeg at the local disk.
    class Input < T::Struct
      extend T::Sig

      const :url, String
      const :protocols, String
      # Options for how it's read, before -i.
      const :options, T::Array[String], default: []
      # A second input with the sound, for a source that sends picture and
      # sound apart (YouTube's live playlists): input 1 to ffmpeg.
      const :audio, T.nilable(Input), default: nil

      # Everything ffmpeg is told about where to read: each input's options,
      # whitelist and -i.
      sig { returns(T::Array[String]) }
      def args = options + [ "-protocol_whitelist", protocols, "-i", url ] + (audio&.args || [])

      # How long a live source may say nothing before the read fails (and
      # the relay reconnects), in microseconds as ffmpeg takes it.
      LIVE_TIMEOUT_US = 10_000_000

      sig { params(path: String).returns(Input) }
      def self.file(path) = new(url: "file:#{path}", protocols: "file")

      # Whether this machine's ffmpeg takes -tls_verify on an RTSP input:
      # asked of the build once, as its own help lists the demuxer's options.
      sig { returns(T::Boolean) }
      def self.rtsp_tls_verify?
        known = @rtsp_tls_verify
        return known unless known.nil?

        found = begin
          ToolRunner.run(%w[ffmpeg -hide_banner -h demuxer=rtsp], timeout: 20).stdout.include?("-tls_verify")
        rescue ToolRunner::Error, SystemCallError
          false
        end
        @rtsp_tls_verify = T.let(found, T.nilable(T::Boolean))
        found
      end

      # A remote transcoder reads over Stream's and fog's web tiers, for
      # hours when the file is big and its share slow (Optimizer): a dropped
      # connection or a swap's 502 picks up where it was, by range, for
      # about half a minute. A 4xx is the run being over, and ends the read.
      REMOTE_READ = %w[-reconnect 1 -reconnect_on_network_error 1 -reconnect_on_http_error 5xx -reconnect_delay_max 30].freeze

      sig { params(url: String).returns(Input) }
      def self.remote(url) = new(url: url, protocols: "http,https,tcp,tls", options: REMOTE_READ)

      # A camera speaks RTSP over interleaved TCP (-rtsp_transport tcp), so
      # rtsps with ?enableSrtp works as given and no UDP port has to reach
      # the container. A source that trusts its own certificate (a camera's
      # is self-signed) is read with -tls_verify 0 — for RTSP only where the
      # build's RTSP demuxer has the option: ffmpeg 9's does, and verifies by
      # default; jellyfin-ffmpeg 7.1's doesn't, never verifies RTSP's TLS,
      # and its ffmpeg refuses an option it doesn't know (its ffprobe only
      # warns), so the relay never started (2026-10-09).
      #
      # A YouTube or MLB.tv stream is read from the playlists its link
      # resolves to (LiveStreams::Resolver) — resolved here unless the caller
      # has them already, as the relay does off the transcoder's loop — and
      # with the User-Agent yt-dlp resolved them under, where it said: MLB.tv's
      # Fastly edge answers ffmpeg's default (Lavf/…) with 403.
      sig { params(stream: LiveStream, resolved: T.nilable(LiveStreams::Resolved)).returns(Input) }
      def self.live(stream, resolved: nil)
        if LiveStreams::Resolver.needed?(stream)
          found = resolved || LiveStreams::Resolver.resolve(stream)
          sound = found.audio
          agent = found.user_agent
          return web(found.video, audio: sound ? web(sound, user_agent: agent) : nil, user_agent: agent)
        end

        url = stream.url.to_s
        scheme = URI.parse(url).scheme.to_s.downcase
        trust = stream.trust_certificate ? %w[-tls_verify 0] : []
        if scheme.start_with?("rtsp")
          new(url: url, protocols: "rtsp,rtsps,tcp,tls,udp,rtp,srtp",
            options: [ "-rtsp_transport", "tcp", "-timeout", LIVE_TIMEOUT_US.to_s ] + (rtsp_tls_verify? ? trust : []))
        else
          web(url, trust: trust)
        end
      end

      sig { params(url: String, trust: T::Array[String], audio: T.nilable(Input), user_agent: T.nilable(String)).returns(Input) }
      def self.web(url, trust: [], audio: nil, user_agent: nil)
        agent = user_agent.present? ? [ "-user_agent", user_agent ] : []
        new(url: url, protocols: "http,https,tcp,tls,crypto", audio: audio,
          options: [ "-rw_timeout", LIVE_TIMEOUT_US.to_s, "-reconnect", "1", "-reconnect_streamed", "1" ] + trust + agent)
      end
      private_class_method :web
    end

    # A keyframe whenever a frame crosses into the next slot of the grid
    # since the last one forced (and on the first frame). Grid slots are
    # whole multiples of `every` from the file's start, and a run always
    # starts on one, so this cuts in the same places whether ffmpeg counts
    # the expression's t from the file's start under -copyts or from the
    # run's — which varies with the ffmpeg and even the input (seen both
    # ways on jellyfin-ffmpeg 7 and ffmpeg 9). The old
    # gte(t, start + n_forced*every) never fired on the second kind: a
    # conversion started anywhere but the top got the encoder's own 10 s GOPs.
    sig { params(every: Float).returns(String) }
    def self.grid_keyframes(every)
      slot = ->(time) { "floor((#{time}+0.0005)/#{format('%.3f', every)})" }
      "expr:if(isnan(prev_forced_t),1,gt(#{slot.call('t')},#{slot.call('prev_forced_t')}))"
    end

    # What ffmpeg takes off an input seek when the file has B-frames and its
    # container doesn't seek by presentation time (Matroska, unlike MP4):
    # 3/23 s, its guess at how far a frame's decode time runs ahead.
    SEEK_BACKOFF = T.let(3.0 / 23, Float)
    # How far past a keyframe a seek for it aims: the index is in whole
    # milliseconds, and a seek a hair before the keyframe lands on the one
    # before it.
    SEEK_PAST = 0.010

    # Where a run copying video seeks to start on this GOP's keyframe. The
    # rows don't say whether a file has B-frames, so the seek is one that
    # lands on the keyframe either way: past it by the backoff and a
    # little, which is still inside the GOP unless the GOP is shorter than
    # that — then just past the keyframe, right for a file without them.
    # What a run really started on is read back from its fragments
    # (Fragment), never taken from here.
    sig { params(plan: SegmentPlan, gop: Integer, container: String).returns(Float) }
    def self.copy_seek(plan, gop, container = "")
      start = plan.gop_start_ms(gop) / 1000.0
      # MPEG-TS and MPEG-PS have no index to seek by: ffmpeg lands on the
      # first keyframe after where it's sent, so it's sent well before this
      # one. A run that starts a GOP early makes one GOP more (Publisher).
      return [ start - TIMESTAMP_SEEK_LEAD, plan.gop_start_ms(0) / 1000.0 ].max if UNINDEXED.any? { |name| container.include?(name) }

      length = plan.gop_end_ms(gop) / 1000.0 - start
      start + (length > SEEK_BACKOFF + (SEEK_PAST * 2) ? SEEK_BACKOFF + SEEK_PAST : SEEK_PAST)
    end

    # Containers ffmpeg seeks in by searching timestamps, landing past them.
    UNINDEXED = %w[mpegts mpeg].freeze
    TIMESTAMP_SEEK_LEAD = 1.5

    # How fast a run reads once past its burst, in times real time.
    sig { returns(Float) }
    def self.readrate = Float(ENV.fetch("STREAM_READRATE", "2"))

    # Seconds of the file a run reads as fast as it can before the throttle:
    # the web player's whole buffer goal (maxBufferLength, 60 s, in
    # frontend/src/components/player/source.ts). At 30 s, every start and
    # seek filled the rest of that buffer at 2x, and each of those segment
    # requests held a Puma thread for 2.5 s waiting on the throttle.
    sig { returns(Float) }
    def self.readrate_burst = Float(ENV.fetch("STREAM_READRATE_BURST", "60"))

    # The picture as one run makes it: the session's decision, or a smaller
    # version of it. Lenient, as a stored decision is (StoredDecision).
    class VideoPlan < T::Struct
      extend T::Sig

      const :index, T.nilable(Integer), default: nil
      const :copy, T::Boolean
      const :codec, T.nilable(String), default: nil
      const :height, T.nilable(Integer), default: nil
      const :tonemap, T::Boolean, default: false
      const :retag_hvc1, T::Boolean, default: false
      const :burn_subtitle, T.nilable(Integer), default: nil
      const :deinterlace, T::Boolean, default: false
      const :dv_strip, T::Boolean, default: false
      const :dv_tag, T.nilable(String), default: nil
      # A smaller version: a keyframe wherever the original has one and
      # nowhere else, at this bitrate.
      const :variant_keyframes, T::Boolean, default: false
      const :variant_bitrate, T.nilable(Integer), default: nil

      sig { params(video: T::Hash[String, T.untyped]).returns(VideoPlan) }
      def self.from(video)
        new(index: video["index"], copy: video["copy"] ? true : false, codec: video["codec"], height: video["height"], tonemap: video["tonemap"] ? true : false,
          retag_hvc1: video["retag_hvc1"] ? true : false, burn_subtitle: video["burn_subtitle"], deinterlace: video["deinterlace"] ? true : false,
          dv_strip: video["dv_strip"] ? true : false, dv_tag: video["dv_tag"])
      end

      sig { params(height: Integer, bitrate: Integer).returns(VideoPlan) }
      def smaller(height, bitrate) = with(copy: false, height: height, variant_keyframes: true, variant_bitrate: bitrate)
    end

    sig do
      params(session: PlaybackSession, plan: SegmentPlan, start_gop: Integer, directory: Pathname,
        profile: Encoders::Profile, input: T.nilable(Input), variant: T.nilable(Variants::Variant), pace: T.nilable(Pace)).returns(T::Array[String])
    end
    def self.build(session, plan, start_gop:, directory:, profile:, input: nil, variant: nil, pace: nil)
      file = T.must(session.media_file)
      input ||= Input.file(file.path)
      decision = session.decision
      video = VideoPlan.from(decision.fetch("video"))
      height = variant&.height
      # A smaller version: the same picture converted to its height, with a
      # keyframe wherever the original has one and nowhere else, so its GOPs
      # are the original's (SegmentPlan).
      video = video.smaller(height, variant_bitrate(height)) if height
      audio = decision["audio"]
      trim_at = T.let(nil, T.nilable(Float))
      start = plan.gop_start_ms(start_gop) / 1000.0

      args = %w[ffmpeg -hide_banner -loglevel warning -nostdin -y]
      args += profile.device_args unless video.copy
      # Throttle: the player's buffer goal arrives at disk speed so starting
      # and seeking are instant, then the run reads at twice real time, so a
      # paused or abandoned session doesn't process the whole film. On a
      # slow share, or for a channel tuned ahead, less; a run that only
      # repackages, not at all (Pace).
      unless pace && !pace.throttled
        args += [ "-readrate", (pace&.rate || readrate).to_s, "-readrate_initial_burst", (pace&.burst || readrate_burst).to_s ]
      end
      # -seek_timestamp: -ss is an absolute timestamp, the timeline the
      # keyframe index and -copyts use, not an offset from the file's start
      # time (AAC priming gives many files a start of -0.021 s).
      # A smaller version decodes from the original's keyframe, and a seek
      # that decodes drops any frame before it: 10 ms early, so that
      # keyframe is kept however its time was rounded.
      # A copy seeks by the file's own timestamps (the keyframe index's):
      # the first GOP's not at all. A conversion seeks from the file's start
      # instead: ffmpeg's accurate seek under -copyts drops every frame of a
      # file whose timestamps start far from 0 (a broadcast recording at
      # 95,000 s) when told an absolute time.
      origin = start_time(file)
      if video.copy
        seek = start_gop.zero? ? nil : copy_seek(plan, start_gop, file.container.to_s)
        args += [ "-seek_timestamp", "1", "-ss", format("%.3f", seek) ] if seek
      else
        at = video.variant_keyframes ? start - 0.010 : start
        # MPEG-TS and MPEG-PS seek past where they're sent: sent well before,
        # and the picture trimmed to the slot (trim, in the file's own time).
        lead = UNINDEXED.any? { |name| file.container.to_s.include?(name) } && at > origin ? GRID_SEEK_LEAD : 0.0
        args += [ "-ss", format("%.3f", [ at - origin - lead, 0.0 ].max) ]
        trim_at = at if lead.positive?
      end
      # Copied video starts on the keyframe the seek lands on, and the sound
      # has to start there with it: ffmpeg's accurate seek would cut a
      # converted track at -ss, past the keyframe, and leave the run's first
      # fragment short of the sound a run passing through gives the same GOP.
      args << "-noaccurate_seek" if video.copy
      # Timestamps where the container has none (AVI's packets carry no
      # PTS; TS, MPEG-PS and FLV can drop some), and whenever video is
      # copied (Jellyfin does the same): without them a copy writes empty
      # or misplaced fragments.
      args += %w[-fflags +genpts] if video.copy || GENPTS_CONTAINERS.any? { |name| file.container.to_s.include?(name) }
      args += input.args
      coding = video_args(video, start, profile, plan.target_ms / 1000.0, trim_at: trim_at)
      burn = video.burn_subtitle
      if burn
        # A picture subtitle drawn in: the picture made SDR first (trimmed,
        # deinterlaced, tone-mapped — R6: overlaying first made 8-bit of HDR
        # and drew the subtitle in PQ), the subtitle scaled to it and laid
        # over, then the encoder's own scaling and upload.
        at = T.must(coding.index("-vf"))
        chain = coding.fetch(at + 1).split(",")
        coding = coding[0...at].to_a + coding[(at + 2)..].to_a
        before = chain.take_while { |filter| filter.start_with?("trim=", "bwdif", "tonemap", "zscale", "format=gbrpf32le", "libplacebo") }
        after = chain.drop(before.size)
        prepared = before.empty? ? "[0:#{T.must(video.index)}]null[picture]" : "[0:#{T.must(video.index)}]#{before.join(',')}[picture]"
        graph = "#{prepared};[0:#{burn.to_i}][picture]scale2ref=w=main_w:h=main_h[sub][base];" \
                "[base][sub]overlay=eof_action=pass:repeatlast=0#{after.empty? ? '' : ",#{after.join(',')}"}[burned]"
        args += [ "-filter_complex", graph, "-map", "[burned]" ]
      else
        args += [ "-map", "0:#{T.must(video.index)}" ]
      end
      args += [ "-map", "0:#{audio.fetch('index')}" ] if audio
      args += coding
      args += audio_args(audio, trim_at: trim_at) if audio
      args + output_args(audio, start_gop, directory)
    end

    sig do
      params(video: VideoPlan, start: Float, profile: Encoders::Profile, every: Float, trim_at: T.nilable(Float)).returns(T::Array[String])
    end
    def self.video_args(video, start, profile, every, trim_at: nil)
      if video.copy
        args = %w[-c:v copy]
        # Dolby Vision to a client without it: the RPU stripped, the HDR10
        # base layer played (R6). Profile 5 to one with it: tagged dvh1,
        # which is how it says so; every other HEVC, hvc1 for Safari.
        args += %w[-bsf:v dovi_rpu=strip=1] if video.dv_strip
        tag = video.dv_tag || (video.retag_hvc1 || video.codec == "hevc" ? "hvc1" : nil)
        return tag ? args + [ "-tag:v", tag ] : args
      end

      height = video.height.to_i
      filters = []
      # Started early (an unindexed container): from the slot's start on.
      filters << format("trim=start=%.3f", trim_at) if trim_at
      # Fields woven into frames before anything else looks at them (R6):
      # one frame per frame, so the grid's keyframes stay where they were.
      filters << "bwdif=mode=send_frame" if video.deinterlace
      # On VideoToolbox, scale_vt tone-maps as it scales, unless a subtitle
      # is drawn in: that has to land on the picture once it's SDR (R6), so
      # the picture is tone-mapped in software before it.
      hardware_tonemap = video.tonemap && profile.hardware_tonemap? && video.burn_subtitle.nil?
      filters << profile.tonemap_filter if video.tonemap && !hardware_tonemap && profile.tonemap_filter
      # Keyframes on the plan's grid, so every GOP fragment is exactly one
      # planned segment; a smaller version copies the original's (and the
      # encoder adds none of its own), so its fragments are the original's GOPs.
      keyframes = video.variant_keyframes ? "source" : grid_keyframes(every)
      encoder = profile.kind
      args = encoder_args(filters, height, keyframes, encoder, tonemap: hardware_tonemap ? true : false)
      args += %w[-g 1000000] if video.variant_keyframes
      rate = video.variant_bitrate
      rate ? args + [ "-b:v", "#{rate}k", "-maxrate", "#{rate}k", "-bufsize", "#{rate * 2}k" ] : args
    end

    sig do
      params(filters: T::Array[T.nilable(String)], height: Integer, keyframes: String, encoder: Encoders::Kind, tonemap: T::Boolean)
        .returns(T::Array[String])
    end
    def self.encoder_args(filters, height, keyframes, encoder, tonemap: false)
      case encoder
      when Encoders::Kind::Vaapi
        filters += [ "format=nv12", "hwupload", "scale_vaapi=w=-2:h=#{height}" ]
        [ "-vf", filters.compact.join(","), "-c:v", "h264_vaapi", "-qp", "22", "-force_key_frames", keyframes ]
      when Encoders::Kind::Software
        filters += [ "scale=-2:#{height}:flags=bicubic", "format=yuv420p" ]
        [ "-vf", filters.compact.join(","), "-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
          "-maxrate", "#{bitrate_for(height)}k", "-bufsize", "#{bitrate_for(height) * 2}k", "-profile:v", "high",
          "-sc_threshold", "0", "-force_key_frames", keyframes ]
      when Encoders::Kind::Videotoolbox
        filters += [ "hwupload", scale_vt(height, tonemap) ]
        [ "-vf", filters.compact.join(","), "-c:v", "h264_videotoolbox", "-realtime", "1", "-profile:v", "high",
          "-b:v", "#{bitrate_for(height) / 2}k", "-maxrate", "#{bitrate_for(height)}k", "-bufsize", "#{bitrate_for(height) * 2}k",
          "-force_key_frames", keyframes ]
      else T.absurd(encoder)
      end
    end

    # Containers whose packets can come without timestamps.
    GENPTS_CONTAINERS = %w[avi mpegts mpeg flv asf].freeze

    # How far before a conversion's start an unindexed container is sent
    # (UNINDEXED): past a GOP, so it lands on a keyframe before the start.
    GRID_SEEK_LEAD = 10.0

    # Where the file's timestamps start (its probe), 0 when it doesn't say.
    sig { params(file: MediaFile).returns(Float) }
    def self.start_time(file) = file.probe.is_a?(Hash) ? file.probe.dig("format", "start_time").to_f : 0.0

    sig { params(audio: T::Hash[String, T.untyped], trim_at: T.nilable(Float)).returns(T::Array[String]) }
    def self.audio_args(audio, trim_at: nil)
      # AAC out of TS, AVI or a bare .aac is ADTS, which fMP4 can't carry:
      # without the filter every such copy failed ("Malformed AAC bitstream",
      # exit 255). It passes AAC that's already MP4's own untouched.
      if audio["copy"]
        # Copied sound can't be trimmed: its packets before the start are
        # dropped instead (Jellyfin's TrimCopiedAudio).
        filters = []
        filters << "aac_adtstoasc" if audio["codec"] == "aac"
        filters << format("noise=drop=lt(pts*tb\\,%.3f)", trim_at) if trim_at
        return filters.empty? ? %w[-c:a copy] : [ "-c:a", "copy", "-bsf:a", filters.join(",") ]
      end

      coding = case audio["codec"]
      when "eac3" then %W[-c:a eac3 -b:a 640k -ac #{audio['channels'] || 6}]
      else %w[-c:a aac -b:a 192k -ac 2]
      end
      trim_at ? [ "-af", format("atrim=start=%.3f", trim_at) ] + coding : coding
    end

    sig { params(audio: T.nilable(T::Hash[String, T.untyped]), start_gop: Integer, directory: Pathname).returns(T::Array[String]) }
    def self.output_args(audio, start_gop, directory)
      movflags = "+frag_discont"
      # AC-3/E-AC-3 in fMP4 can't write moov before the first packet is
      # parsed (spikes.md › B).
      movflags += "+delay_moov" if %w[ac3 eac3].include?(audio&.dig("codec"))
      [
        "-copyts", "-avoid_negative_ts", "disabled", "-max_muxing_queue_size", "2048",
        "-f", "hls", "-hls_time", "0.001", "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
        "-hls_segment_options", "movflags=#{movflags}", "-hls_flags", "temp_file", "-start_number", start_gop.to_s,
        "-hls_segment_filename", directory.join("gop-%d.m4s").to_s, "-hls_playlist_type", "vod", "-hls_list_size", "0",
        directory.join("run.m3u8").to_s
      ]
    end

    # What a smaller version (Variants) streams at: enough to look right,
    # small enough to be worth dropping to.
    sig { params(height: Integer).returns(Integer) }
    def self.variant_bitrate(height)
      if height >= 1000 then 8_000
      elsif height >= 700 then 4_000
      else 1_500
      end
    end

    # Scaling on the media engine (the picture uploaded to it first), and
    # with tonemap, HDR made BT.709 SDR on the way.
    sig { params(height: Integer, tonemap: T::Boolean).returns(String) }
    def self.scale_vt(height, tonemap)
      colour = tonemap ? ":color_matrix=bt709:color_primaries=bt709:color_transfer=bt709" : ""
      "scale_vt=w=-2:h=#{height}#{colour}"
    end

    # A ceiling for the encoder, generous for a LAN.
    sig { params(height: Integer).returns(Integer) }
    def self.bitrate_for(height)
      if height >= 2000 then 30_000
      elsif height >= 1000 then 10_000
      elsif height >= 700 then 5_000
      else 2_500
      end
    end
  end
end
