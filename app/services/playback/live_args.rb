# typed: strict
# frozen_string_literal: true

module Playback
  # The ffmpeg command for a live stream's relay (PROPOSAL §7.8): its
  # address in (FfmpegArgs::Input.live), live fMP4 HLS out — a playlist
  # that slides, its oldest segments deleted as new ones land, so a viewer
  # can pause and go back a few minutes and no further.
  module LiveArgs
    extend T::Sig

    # Segments ask for a second; copied video is cut only where the source
    # put a keyframe, so a camera's own interval decides (UniFi's is 5 s).
    SEGMENT_SECONDS = 1
    # How many the playlist keeps: the window behind live a viewer can go
    # back through — a few minutes at a camera's 5 s keyframes, two at 1 s.
    WINDOW_SEGMENTS = 120

    # A fresh relay numbers its segments from the clock, so a name is never
    # used twice for different pictures — a player's cache can't serve an
    # old one. After a reconnect (append) it carries on the playlist where
    # the last run left it, after a discontinuity, so the playlist only grows
    # and a player already on it keeps going. ffmpeg never writes ENDLIST:
    # a run that stops isn't the end of a live stream, and a player told it
    # was would stop asking.
    sig do
      params(stream: LiveStream, decision: T::Hash[String, T.untyped], directory: Pathname, profile: Encoders::Profile,
        append: T::Boolean, resolved: T.nilable(LiveStreams::Resolved)).returns(T::Array[String])
    end
    def self.build(stream, decision, directory:, profile:, append: false, resolved: nil)
      input = FfmpegArgs::Input.live(stream, resolved: resolved)
      video = decision.fetch("video")
      audio = decision["audio"]
      args = %w[ffmpeg -hide_banner -loglevel error -nostdin -y]
      args += profile.device_args unless video["copy"]
      args += input.args
      # By position among its kind, not the index the probe saw: a camera
      # can list its tracks in another order on the next connection. Sound
      # sent apart is the second input's.
      args += [ "-map", "0:v:0" ]
      args += [ "-map", "#{input.audio ? 1 : 0}:a:#{audio_position(stream, audio.fetch('index'))}" ] if audio
      args += if video["copy"]
        video["codec"] == "hevc" ? %w[-c:v copy -tag:v hvc1] : %w[-c:v copy]
      else
        hardware_tonemap = video["tonemap"] && profile.hardware_tonemap? ? true : false
        software_tonemap = profile.tonemap_filter
        encoding = EncoderArgs.for(profile.kind, height: video["height"].to_i, keyframes: "expr:gte(t,n_forced*#{SEGMENT_SECONDS})",
          quality: EncoderArgs::Quality::Live, tonemap: hardware_tonemap)
        picture = video["tonemap"] && !hardware_tonemap && software_tonemap ? [ software_tonemap ] : []
        FfmpegArgs::Coding.new(picture: picture, output: encoding.filters, codec: encoding.codec).args
      end
      args += FfmpegArgs.audio_args(audio) if audio
      # A web stream's MPEG-TS carries AAC as ADTS, which MP4 can't hold;
      # the filter repackages it, and passes a camera's AAC through as is.
      args += %w[-bsf:a aac_adtstoasc] if audio && audio["copy"] && audio["codec"] == "aac"
      # jellyfin-ffmpeg 7.1's RTSP reader marks no AAC packet a keyframe
      # (UniFi's cameras; ffmpeg 9 marks every one), and a copy waits for a
      # keyframe before it writes any — so segments held video alone, and
      # Chrome buffers nothing from a track that never arrives. Every audio
      # frame stands alone, so the wait is never needed.
      args += %w[-copyinkf:a] if audio && audio["copy"]
      flags = %w[delete_segments independent_segments program_date_time temp_file omit_endlist]
      flags += %w[append_list discont_start] if append
      # Appending, ffmpeg counts on from the playlist itself.
      start_number = append ? 0 : Time.current.to_i
      args + [
        "-f", "hls", "-hls_time", SEGMENT_SECONDS.to_s, "-hls_list_size", WINDOW_SEGMENTS.to_s,
        "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4", "-hls_flags", flags.join("+"),
        "-start_number", start_number.to_s, "-hls_segment_filename", directory.join("seg-%d.m4s").to_s,
        directory.join(LiveCache::PLAYLIST).to_s
      ]
    end

    sig { params(stream: LiveStream, index: Integer).returns(Integer) }
    def self.audio_position(stream, index)
      audio = stream.media_streams.select { |row| row.kind_enum == MediaStream::Kind::Audio }
      audio.index { |row| row.index == index } || 0
    end
    private_class_method :audio_position
  end
end
