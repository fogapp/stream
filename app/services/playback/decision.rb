# typed: strict
# frozen_string_literal: true

module Playback
  # The cheapest path from a file to a perfect picture on this client
  # (PROPOSAL §6.2), stream by stream:
  #
  #   direct play  → the original file, untouched
  #   remux        → same streams, repackaged as fMP4 HLS
  #   audio        → video copied, audio converted
  #   optimized    → the file's optimized version, played as-is (§5.5)
  #   video        → video converted (the expensive one; always explained)
  #
  # Every choice carries a reason in plain words for the Playback decisions
  # page (§7.6). Subtitles never enter into it: they render in the browser.
  class Decision
    extend T::Sig

    # Software encoding can't keep a 4K encode in real time on a typical
    # home server's CPU; a hardware encoder can.
    SOFTWARE_MAX_HEIGHT = 1080

    class Video < T::Struct
      const :index, Integer
      const :copy, T::Boolean
      const :codec, String
      const :height, T.nilable(Integer)
      const :tonemap, T::Boolean
      # HEVC in MP4 must be tagged hvc1 for Safari; hev1 won't play.
      const :retag_hvc1, T::Boolean
      # A picture subtitle's stream, drawn into the video.
      const :burn_subtitle, T.nilable(Integer), default: nil
      # Interlaced: deinterlaced as it's converted (R6).
      const :deinterlace, T::Boolean, default: false
      # Dolby Vision copied to a client without it: its RPU stripped, the
      # HDR10 base layer played (R6).
      const :dv_strip, T::Boolean, default: false
      # Dolby Vision profile 5 copied to a client with it: tagged dvh1 (R6).
      const :dv_tag, T.nilable(String), default: nil
    end

    class Audio < T::Struct
      const :index, Integer
      const :copy, T::Boolean
      const :codec, String
      const :channels, T.nilable(Integer)
    end

    # Why the picture isn't copied: its reason code, the first half of its
    # reason, and whether HDR is all that's wrong with it.
    class VideoProblem < T::Struct
      const :code, String
      const :text, String
      const :tonemap_only, T::Boolean, default: false
    end

    sig { returns(PlaybackSession::Method) }
    attr_reader :method

    sig { returns(T.nilable(Video)) }
    attr_reader :video

    sig { returns(T.nilable(Audio)) }
    attr_reader :audio

    sig { returns(T::Array[String]) }
    attr_reader :reasons

    sig { returns(T.nilable(String)) }
    attr_reader :refusal

    # A live stream's decision (PROPOSAL §7.8): from the tracks its probe
    # saw, always relayed — never played as-is, since the browser never
    # opens its address — and never converted only to be smaller: the
    # browser scales a 4K camera down far more cheaply than converting it
    # live would.
    sig do
      params(stream: LiveStream, capabilities: Capabilities, audio_index: T.nilable(Integer), max_height: Integer,
        device_name: String).returns(Decision)
    end
    def self.live(stream, capabilities, audio_index: nil, max_height: SOFTWARE_MAX_HEIGHT, device_name: "This browser")
      new(nil, capabilities, audio_index: audio_index, max_height: max_height, device_name: device_name, live_stream: stream)
    end

    sig do
      params(file: T.nilable(MediaFile), capabilities: Capabilities, audio_index: T.nilable(Integer), max_height: Integer,
        device_name: String, burn_subtitle: T.nilable(Integer), live_stream: T.nilable(LiveStream), constraints: Constraints,
        fell_back: T.nilable(String)).void
    end
    def initialize(file, capabilities, audio_index: nil, max_height: SOFTWARE_MAX_HEIGHT, device_name: "This browser", burn_subtitle: nil,
      live_stream: nil, constraints: Constraints::NONE, fell_back: nil)
      @file = file
      # What a fallback rules out, and why it came to that (R2).
      @constraints = constraints
      @fell_back = fell_back
      # Why each choice was made, as codes (R6): what learning (R3) and the
      # Playback page group by.
      @codes = T.let([], T::Array[String])
      @live = live_stream
      @burn = T.let(file && burn_subtitle && Subtitles::Tracks.burnable?(file, burn_subtitle) ? burn_subtitle : nil, T.nilable(Integer))
      # What this device is known to claim and not manage, taken away (R6).
      @caps = T.let(Quirks.apply(capabilities, device_name), Capabilities)
      @device = device_name
      @max_height = max_height
      @reasons = T.let([], T::Array[String])
      @refusal = T.let(nil, T.nilable(String))
      @video_problem = T.let(nil, T.nilable(VideoProblem))
      @optimized = T.let(nil, T.nilable(OptimizedVersion))
      @video = T.let(plan_video, T.nilable(Video))
      @audio = T.let(plan_audio(audio_index), T.nilable(Audio))
      @method = T.let(choose_method, PlaybackSession::Method)
      @reasons.unshift(fell_back) if fell_back
    end

    sig { returns(Constraints) }
    attr_reader :constraints

    sig { returns(T::Array[String]) }
    def reason_codes = @codes.uniq

    sig { returns(T::Boolean) }
    def playable? = @refusal.nil?

    # One sentence for the badge row on the admin page.
    sig { returns(String) }
    def summary
      return T.must(@refusal) unless playable?

      case @method
      when PlaybackSession::Method::Direct then "Plays as-is"
      else @reasons.first || "Repackaged"
      end
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      {
        "method" => @method.serialize, "summary" => summary, "reasons" => @reasons, "refusal" => @refusal,
        "video" => @video&.serialize, "audio" => @audio&.serialize, "container" => container_label,
        "capabilities" => @caps.to_json_hash, "reason_codes" => @codes.uniq
      }.merge(@optimized ? { "optimized_version_id" => @optimized.id } : {})
        .merge(direct_mime_type ? { "direct_mime_type" => direct_mime_type } : {})
        .merge(@constraints.none? ? {} : { "constraints" => @constraints.to_h })
    end

    # The optimized version this plays, when it plays one.
    sig { returns(T.nilable(OptimizedVersion)) }
    attr_reader :optimized

    # The MIME type a <video> element is told for direct play.
    sig { returns(T.nilable(String)) }
    def direct_mime_type
      return "video/mp4" if @method == PlaybackSession::Method::Optimized

      case container_key
      when "mp4" then "video/mp4"
      when "webm" then "video/webm"
      end
    end

    private

    sig { returns(T::Array[MediaStream]) }
    def streams
      @streams ||= T.let((@live&.media_streams || T.must(@file).media_streams).to_a, T.nilable(T::Array[MediaStream]))
    end

    sig { returns(T.nilable(MediaStream)) }
    def primary_stream
      @primary_stream ||= T.let(streams.find { |candidate| candidate.kind_enum == MediaStream::Kind::Video }, T.nilable(MediaStream))
    end

    # ffprobe's own record of a stream, for what the rows don't keep.
    sig { params(stream: MediaStream).returns(T.nilable(T::Hash[String, T.untyped])) }
    def probed(stream) = Array(@file&.probe&.dig("streams")).find { |candidate| candidate["index"] == stream.index }

    sig { returns(T.nilable(Video)) }
    def plan_video
      stream = primary_stream
      return nil if stream.nil?

      key = video_key(stream)
      hdr = stream.hdr_format_enum
      # On either path: the direct one is checked when the method is chosen.
      codec_ok = @caps.video.include?(key) || @caps.stream_video.include?(key)
      hdr_ok = hdr.nil? || hdr_supported?(hdr)
      height = stream.height
      deinterlace = @live.nil? && interlaced?(stream)
      blocker = @live ? nil : copy_blocker(stream, key)

      if @burn
        note(VideoProblem.new(code: "burn_subtitle", text: "Subtitles drawn into the picture (disc subtitles nothing here can show)"))
        return converted_video(stream, height, tonemap: !hdr.nil?, deinterlace: deinterlace, burn: @burn)
      end

      if codec_ok && hdr_ok && blocker.nil?
        return copied_video(stream, height) unless @constraints.convert_video

        # It should have played, and didn't: converted all the same, as SDR
        # H.264 (the one picture every client here decodes).
        note(VideoProblem.new(code: "fallback", text: "#{VIDEO_LABELS.fetch(key, stream.codec.to_s.upcase)} video didn't play here"))
      else
        note(blocker || video_problem(stream, key, codec_ok))
      end
      # Converted to 8-bit H.264, any HDR picture is tone-mapped, whatever the
      # screen: PQ in an SDR stream is washed out everywhere.
      converted_video(stream, height, tonemap: !hdr.nil?, deinterlace: deinterlace)
    end

    sig { params(problem: VideoProblem).void }
    def note(problem)
      @video_problem = problem
      @codes << problem.code
    end

    # The picture as it is: tagged and stripped for this client as its
    # Dolby Vision needs (R6).
    sig { params(stream: MediaStream, height: T.nilable(Integer)).returns(Video) }
    def copied_video(stream, height)
      dv = stream.hdr_format_enum == MediaStream::HdrFormat::DolbyVision
      dv_client = @caps.hdr.include?("dolby_vision")
      profile = stream.dolby_vision_profile
      strip = dv && !(dv_client && [ 5, 8 ].include?(profile))
      tag = dv && dv_client && profile == 5 ? "dvh1" : nil
      hev1 = stream.codec == "hevc" && %w[hev1 dvhe].include?(stream.codec_tag || codec_tag(stream))
      Video.new(index: stream.index, copy: true, codec: stream.codec.to_s, height: height, tonemap: false,
        retag_hvc1: hev1 || (strip && %w[dvh1 dvhe].include?(stream.codec_tag.to_s)), dv_strip: strip, dv_tag: tag)
    end

    # The picture converted to H.264, for the reason in @video_problem.
    sig do
      params(stream: MediaStream, height: T.nilable(Integer), tonemap: T::Boolean, deinterlace: T::Boolean, burn: T.nilable(Integer))
        .returns(Video)
    end
    def converted_video(stream, height, tonemap:, deinterlace:, burn: nil)
      target = conversion_height(height)
      problem = T.must(@video_problem)
      outcome =
        if tonemap && problem.tonemap_only then "tone-mapped to SDR H.264 #{target}p"
        else "converted to H.264 #{target}p#{tonemap ? ' with tone mapping' : ''}"
        end
      @reasons << "#{problem.text} — #{deinterlace && burn.nil? ? "deinterlaced and #{outcome}" : outcome}"
      Video.new(index: stream.index, copy: false, codec: "h264", height: target, tonemap: tonemap, retag_hvc1: false,
        burn_subtitle: burn, deinterlace: deinterlace)
    end

    # How tall a conversion is made: the picture's own height, unless the
    # encoder or the screen is smaller (R6: a copy is never held to the
    # screen — the browser scales far more cheaply than a conversion).
    sig { params(height: T.nilable(Integer)).returns(Integer) }
    def conversion_height(height)
      target = [ height || SOFTWARE_MAX_HEIGHT, @max_height, @caps.max_height ].min
      target - (target % 2)
    end

    # Fields of an interlaced picture (MPEG-2 DVDs, 1080i broadcast, AVCHD):
    # shown combed if copied (R6).
    sig { params(stream: MediaStream).returns(T::Boolean) }
    def interlaced?(stream) = %w[tt bb tb bt].include?(stream.field_order.to_s)

    # Why a picture whose codec this client takes still can't be copied to
    # it (R6); nil when it can.
    sig { params(stream: MediaStream, key: String).returns(T.nilable(VideoProblem)) }
    def copy_blocker(stream, key)
      label = VIDEO_LABELS.fetch(key, stream.codec.to_s.upcase)
      chroma = stream.chroma
      codec = stream.codec.to_s
      level = stream.level
      limit = @caps.levels[codec]
      smooth = @caps.smooth[codec]
      height = stream.height
      if chroma.present? && chroma != "420"
        VideoProblem.new(code: "chroma", text: "#{CHROMA_LABELS.fetch(chroma, chroma)} #{label} video isn't decoded by browsers")
      elsif interlaced?(stream)
        VideoProblem.new(code: "interlaced", text: "Interlaced #{label} video")
      elsif level && limit && level > limit
        VideoProblem.new(code: "level", text: "#{label} at level #{level_label(codec, level)} is more than this device decodes")
      elsif height && smooth && height > smooth
        VideoProblem.new(code: "smooth", text: "#{height}p #{label} doesn't play smoothly here")
      end
    end

    CHROMA_LABELS = T.let({ "422" => "4:2:2", "444" => "4:4:4", "411" => "4:1:1", "400" => "Greyscale" }.freeze, T::Hash[String, String])

    # ffprobe's level number as people say it: H.264 51 is 5.1, HEVC 153 is 5.1.
    sig { params(codec: String, level: Integer).returns(String) }
    def level_label(codec, level)
      case codec
      when "h264" then format("%.1f", level / 10.0)
      when "hevc" then format("%.1f", level / 30.0)
      else level.to_s
      end
    end

    sig { params(requested: T.nilable(Integer)).returns(T.nilable(Audio)) }
    def plan_audio(requested)
      tracks = streams.select { |candidate| candidate.kind_enum == MediaStream::Kind::Audio }
      # Not a commentary or a description track, unless asked for: one
      # flagged default by mistake played over the film (R6).
      main = tracks.reject { |track| track.comment || track.visual_impaired || track.hearing_impaired }
      stream = tracks.find { |track| track.index == requested } || main.find(&:default) || main.first || tracks.find(&:default) || tracks.first
      return nil if stream.nil?

      codec = stream.codec.to_s
      channels = stream.channels || 2
      if @constraints.convert_audio
        @codes << "fallback"
        @reasons << "#{audio_label(codec, channels)} audio didn't play here — converted to AAC stereo"
        return Audio.new(index: stream.index, copy: false, codec: "aac", channels: 2)
      end
      if @caps.audio.include?(codec) && channels <= @caps.max_audio_channels
        return Audio.new(index: stream.index, copy: true, codec: codec, channels: channels)
      end

      why = @caps.audio.include?(codec) ? "#{channel_label(channels)} is more than this device plays" : "#{audio_label(codec, channels)} audio isn't supported here"
      @codes << (@caps.audio.include?(codec) ? "audio_channels" : "audio_codec")
      convert_audio(stream.index, channels, why)
    end

    sig { params(index: Integer, channels: Integer, why: String).returns(Audio) }
    def convert_audio(index, channels, why)
      surround = channels > 2 && @caps.max_audio_channels >= 6 && @caps.audio.include?("eac3")
      target = surround ? Audio.new(index: index, copy: false, codec: "eac3", channels: [ channels, 6 ].min) :
                          Audio.new(index: index, copy: false, codec: "aac", channels: 2)
      @reasons << "#{why} — converted to #{audio_label(target.codec, T.must(target.channels))}"
      target
    end

    # What a repackaged stream (fMP4 HLS) can carry as-is. A browser plays
    # MP3 or Vorbis in a file it opens itself, but not inside fMP4: hls.js
    # reads MP3's sample entry as a bare "mp4a" that MediaSource refuses,
    # and Apple's HLS takes neither.
    STREAMABLE_AUDIO = T.let(%w[aac ac3 eac3 flac opus alac].to_set.freeze, T::Set[String])

    # The audio a repackaged stream can carry: a copy only of what fMP4 holds,
    # what this client's streaming path decodes, at a rate it takes (R6).
    sig { params(audio: T.nilable(Audio)).returns(T.nilable(Audio)) }
    def streamable(audio)
      return audio if audio.nil? || !audio.copy

      channels = audio.channels || 2
      label = audio_label(audio.codec, channels)
      rate = streams.find { |candidate| candidate.index == audio.index }&.sample_rate
      why =
        if !STREAMABLE_AUDIO.include?(audio.codec) then "#{label} audio doesn't stream as-is"
        elsif !@caps.stream_audio.include?(audio.codec) then "#{label} audio plays as a file here, not streamed"
        elsif rate && rate > 48_000 then "#{label} audio at #{rate / 1000} kHz doesn't stream as-is"
        end
      return audio if why.nil?

      @codes << "audio_codec"
      convert_audio(audio.index, channels, why)
    end

    sig { returns(PlaybackSession::Method) }
    def choose_method
      video = @video
      audio = @audio
      if video.nil?
        @refusal = "There's no video in this file"
        return PlaybackSession::Method::Direct
      end

      direct = video.copy && !video.retag_hvc1 && !video.dv_strip && (audio.nil? || audio.copy) && direct_container? &&
        first_audio_selected? && @caps.video.include?(video_key(T.must(primary_stream)))
      return PlaybackSession::Method::Direct if direct && !@constraints.no_direct
      return play_optimized if !video.copy && video.burn_subtitle.nil? && !@constraints.no_optimized && optimized_playable?

      @audio = audio = streamable(audio)
      @video = video = streamable_video(video)

      if @caps.hls == Capabilities::Hls::Unsupported
        @refusal = "#{@device} can't play streamed video (no HLS or Media Source support)"
        return PlaybackSession::Method::Remux
      end
      return PlaybackSession::Method::VideoTranscode unless video.copy
      return PlaybackSession::Method::AudioTranscode if audio && !audio.copy

      @reasons.unshift(remux_reason)
      PlaybackSession::Method::Remux
    end

    # The picture a stream can carry as-is: one this client's streaming path
    # decodes, the right way up (R6). Otherwise converted.
    sig { params(video: Video).returns(Video) }
    def streamable_video(video)
      stream = primary_stream
      return video if !video.copy || stream.nil? || @live

      key = video_key(stream)
      label = VIDEO_LABELS.fetch(key, stream.codec.to_s.upcase)
      if !@caps.stream_video.include?(key)
        note(VideoProblem.new(code: "video_codec", text: "#{label} video plays as a file here, not streamed"))
      elsif stream.rotation.to_i % 360 != 0
        note(VideoProblem.new(code: "rotation", text: "Video filmed turned on its side doesn't stream upright as-is"))
      else
        return video
      end
      converted_video(stream, stream.height, tonemap: !stream.hdr_format_enum.nil?, deinterlace: interlaced?(stream))
    end

    sig { returns(String) }
    def remux_reason
      return "Relayed live from #{@live.source} — repackaged as it arrives, no quality loss" if @live
      if @constraints.no_direct && direct_container? && first_audio_selected?
        return "The file didn't play as-is here — repackaged, no quality loss"
      end
      return "#{@device} only plays the first audio track of a file — repackaged with the one you chose" unless first_audio_selected?
      return "HEVC in this file is tagged hev1, which Safari won't open — repackaged as hvc1" if @video&.retag_hvc1

      "#{@device} can't open #{container_label} files — repackaged, no quality loss"
    end

    sig { returns(T::Boolean) }
    def direct_container?
      key = container_key
      !key.nil? && @caps.containers.include?(key)
    end

    # Browsers play a file's first audio track; any other needs a remux.
    sig { returns(T::Boolean) }
    def first_audio_selected?
      chosen = @audio
      return true if chosen.nil?

      first = streams.find { |candidate| candidate.kind_enum == MediaStream::Kind::Audio }
      first&.index == chosen.index
    end

    sig { returns(T.nilable(String)) }
    def container_key
      file = @file
      return nil if file.nil?

      extension = File.extname(file.path).delete(".").downcase
      format = file.container.to_s
      return "mp4" if format.start_with?("mov,mp4") && %w[mp4 m4v mov].include?(extension)
      return "webm" if format.include?("webm") && extension == "webm"

      nil
    end

    sig { returns(String) }
    def container_label = @live ? "live" : File.extname(T.must(@file).path).delete(".").upcase.presence || "these"

    sig { params(stream: MediaStream).returns(String) }
    def video_key(stream)
      ten_bit = stream.bit_depth.to_i > 8
      case stream.codec
      when "h264" then ten_bit ? "h264_10" : "h264"
      when "hevc" then ten_bit ? "hevc_10" : "hevc"
      when "av1" then ten_bit ? "av1_10" : "av1"
      when "vp9" then ten_bit ? "vp9_10" : "vp9"
      else stream.codec.to_s
      end
    end

    # Dolby Vision profile 8 carries an HDR10 base layer any HDR10 display
    # shows; profile 5 has none, so it needs real Dolby Vision support.
    sig { params(hdr: MediaStream::HdrFormat).returns(T::Boolean) }
    def hdr_supported?(hdr)
      case hdr
      when MediaStream::HdrFormat::Hdr10, MediaStream::HdrFormat::Hdr10Plus then @caps.hdr.include?("hdr10")
      when MediaStream::HdrFormat::Hlg then @caps.hdr.include?("hlg")
      when MediaStream::HdrFormat::DolbyVision
        # Profile 5 has no fallback layer: real Dolby Vision or nothing.
        # Profiles 7 and 8 carry an HDR10 base (8.4: HLG) any HDR display
        # shows, with the RPU stripped (copied_video).
        case dolby_vision_profile
        when 5 then @caps.hdr.include?("dolby_vision")
        when 7, 8 then dolby_vision_compatibility == 4 ? @caps.hdr.include?("hlg") : @caps.hdr.include?("hdr10")
        else @caps.hdr.include?("dolby_vision")
        end
      else T.absurd(hdr)
      end
    end

    sig { returns(T.nilable(Integer)) }
    def dolby_vision_profile
      primary_stream&.dolby_vision_profile
    end

    # What a Dolby Vision base layer is besides: 1 HDR10, 4 HLG, 2 SDR, 6 Blu-ray HDR10.
    sig { returns(T.nilable(Integer)) }
    def dolby_vision_compatibility
      stream = primary_stream
      return nil if stream.nil?

      side = Array(probed(stream)&.dig("side_data_list")).find { |data| data["side_data_type"].to_s.include?("DOVI") }
      return nil if side.nil?

      Integer(side["dv_bl_signal_compatibility_id"].to_s, exception: false)
    end

    # What's wrong with a picture nothing about its stream blocks: its codec,
    # or failing that its HDR.
    sig { params(stream: MediaStream, key: String, codec_ok: T::Boolean).returns(VideoProblem) }
    def video_problem(stream, key, codec_ok)
      return VideoProblem.new(code: "hdr", text: "HDR on a screen that can't show it", tonemap_only: true) if codec_ok

      VideoProblem.new(code: "video_codec", text: "#{VIDEO_LABELS.fetch(key, stream.codec.to_s.upcase)} video isn't supported here")
    end

    # A ready optimized version this client plays as-is, carrying the audio
    # track that was asked for.
    sig { returns(T::Boolean) }
    def optimized_playable?
      version = @file&.optimized_version
      return false if version.nil? || !version.ready?
      return false unless @caps.video.include?("h264") && @caps.containers.include?("mp4")
      return false if version.height.to_i > @caps.max_height
      return false if version.audio_stream_index && !@caps.audio.include?("aac")

      audio = @audio
      audio.nil? || audio.index == version.audio_stream_index
    end

    sig { returns(PlaybackSession::Method) }
    def play_optimized
      version = T.must(@file&.optimized_version)
      @optimized = version
      @video = Video.new(index: T.must(@video).index, copy: true, codec: "h264", height: version.height, tonemap: false, retag_hvc1: false)
      audio = @audio
      @audio = audio && Audio.new(index: audio.index, copy: true, codec: "aac", channels: 2)
      @reasons = [ "#{@video_problem&.text} — plays the optimized H.264 #{version.height}p version made ahead of time" ]
      PlaybackSession::Method::Optimized
    end

    VIDEO_LABELS = T.let({
      "h264" => "H.264", "h264_10" => "10-bit H.264", "hevc" => "HEVC", "hevc_10" => "10-bit HEVC", "av1" => "AV1",
      "av1_10" => "10-bit AV1", "vp9" => "VP9", "vp9_10" => "10-bit VP9", "mpeg2video" => "MPEG-2", "vc1" => "VC-1",
      "mpeg4" => "MPEG-4 Part 2", "wmv3" => "WMV"
    }.freeze, T::Hash[String, String])

    AUDIO_LABELS = T.let({
      "aac" => "AAC", "ac3" => "Dolby Digital", "eac3" => "Dolby Digital Plus", "dts" => "DTS", "truehd" => "Dolby TrueHD",
      "flac" => "FLAC", "opus" => "Opus", "mp3" => "MP3", "mp2" => "MP2", "vorbis" => "Vorbis", "pcm_s16le" => "PCM"
    }.freeze, T::Hash[String, String])

    sig { params(codec: String, channels: Integer).returns(String) }
    def audio_label(codec, channels) = "#{AUDIO_LABELS.fetch(codec, codec.upcase)} #{channel_label(channels)}"

    sig { params(channels: Integer).returns(String) }
    def channel_label(channels)
      case channels
      when 1 then "mono"
      when 2 then "stereo"
      when 6 then "5.1"
      when 8 then "7.1"
      else "#{channels}-channel"
      end
    end

    sig { params(stream: MediaStream).returns(T.nilable(String)) }
    def codec_tag(stream)
      probed(stream)&.dig("codec_tag_string")
    end
  end
end
