# typed: strict
# frozen_string_literal: true

module Playback
  # The ffmpeg command for an optimized version (PROPOSAL §5.5): H.264 High
  # 8-bit SDR at no more than the configured height, stereo AAC from the
  # file's main track (MediaStream.main_audio), keyframes every two seconds, moov up front. Every
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

      # The same track a session plays when none is asked for, so the
      # version is one Decision#optimized_playable? accepts.
      audio = MediaStream.main_audio(streams)
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
      # Input#args, so a remote read keeps its reconnect options (REMOTE_READ).
      args += input.args + [ "-map", "0:#{plan.video_index}" ]
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
      software_tonemap = profile.tonemap_filter
      picture = plan.tonemap && !profile.hardware_tonemap? && software_tonemap ? [ software_tonemap ] : []
      encoding = EncoderArgs.for(profile.kind, height: plan.height, keyframes: "expr:gte(t,n_forced*#{KEYFRAME_SECONDS})",
        quality: EncoderArgs::Quality::Optimize, tonemap: plan.tonemap)
      FfmpegArgs::Coding.new(picture: picture, output: encoding.filters, codec: encoding.codec).args
    end
  end
end
