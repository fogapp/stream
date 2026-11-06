# typed: strict
# frozen_string_literal: true

module Playback
  # The ffmpeg command for an optimized version (PROPOSAL §5.5): H.264 High
  # 8-bit SDR at no more than the configured height, stereo AAC from the
  # file's default track, keyframes every two seconds, moov up front. Every
  # browser plays the result as-is. Slower presets than a live run: there
  # is all night.
  module OptimizeArgs
    extend T::Sig

    KEYFRAME_SECONDS = 2

    class Plan < T::Struct
      const :video_index, Integer
      const :audio_index, T.nilable(Integer)
      const :height, Integer
      const :tonemap, T::Boolean
    end

    sig { params(file: MediaFile, max_height: Integer).returns(T.nilable(Plan)) }
    def self.plan(file, max_height:)
      streams = file.media_streams.to_a
      video = streams.find { |stream| stream.kind_enum == MediaStream::Kind::Video }
      return nil if video.nil?

      tracks = streams.select { |stream| stream.kind_enum == MediaStream::Kind::Audio }
      audio = tracks.find(&:default) || tracks.first
      height = [ video.height || max_height, max_height ].min
      Plan.new(video_index: video.index, audio_index: audio&.index, height: height - (height % 2),
        tonemap: !video.hdr_format_enum.nil?)
    end

    sig do
      params(file: MediaFile, plan: Plan, output: String, progress: String, profile: Encoders::Profile,
        input: T.nilable(FfmpegArgs::Input)).returns(T::Array[String])
    end
    def self.build(file, plan, output:, progress:, profile:, input: nil)
      input ||= FfmpegArgs::Input.file(file.path)
      args = %w[ffmpeg -hide_banner -loglevel error -nostdin -y]
      args += profile.device_args
      args += [ "-protocol_whitelist", input.protocols, "-i", input.url, "-map", "0:#{plan.video_index}" ]
      args += [ "-map", "0:#{plan.audio_index}" ] if plan.audio_index
      args += video_args(plan, profile)
      args += %w[-c:a aac -b:a 192k -ac 2] if plan.audio_index
      args + [
        "-map_metadata", "-1", "-map_chapters", "-1", "-movflags", "+faststart",
        "-progress", progress, "-stats_period", "5", "-f", "mp4", output
      ]
    end

    sig { params(plan: Plan, profile: Encoders::Profile).returns(T::Array[String]) }
    def self.video_args(plan, profile)
      filters = []
      filters << profile.tonemap_filter if plan.tonemap && !profile.hardware_tonemap? && profile.tonemap_filter
      keyframes = "expr:gte(t,n_forced*#{KEYFRAME_SECONDS})"
      encoder = profile.kind
      case encoder
      when Encoders::Kind::Vaapi
        filters += [ "format=nv12", "hwupload", "scale_vaapi=w=-2:h=#{plan.height}" ]
        [ "-vf", filters.join(","), "-c:v", "h264_vaapi", "-qp", "20", "-profile:v", "high", "-force_key_frames", keyframes ]
      when Encoders::Kind::Software
        filters += [ "scale=-2:#{plan.height}:flags=lanczos", "format=yuv420p" ]
        [ "-vf", filters.join(","), "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-profile:v", "high",
          "-maxrate", "#{FfmpegArgs.bitrate_for(plan.height)}k", "-bufsize", "#{FfmpegArgs.bitrate_for(plan.height) * 2}k",
          "-force_key_frames", keyframes ]
      when Encoders::Kind::Videotoolbox
        filters += [ "hwupload", FfmpegArgs.scale_vt(plan.height, plan.tonemap) ]
        [ "-vf", filters.join(","), "-c:v", "h264_videotoolbox", "-profile:v", "high",
          "-b:v", "#{FfmpegArgs.bitrate_for(plan.height) * 6 / 10}k", "-maxrate", "#{FfmpegArgs.bitrate_for(plan.height)}k",
          "-bufsize", "#{FfmpegArgs.bitrate_for(plan.height) * 2}k", "-force_key_frames", keyframes ]
      else T.absurd(encoder)
      end
    end
  end
end
