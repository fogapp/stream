# typed: strict
# frozen_string_literal: true

module Transcripts
  # Speech to text for a video with no subtitles (PROPOSAL §5.5): its
  # audio, extracted small, sent to the household's Whisper server.
  class WhisperClient
    extend T::Sig
    include UpstreamHttpClient

    class Error < UpstreamHttpClient::Error; end

    # An hour of speech on a CPU model takes a while.
    READ_TIMEOUT = T.let(2 * 3600, Integer)

    sig { params(setting: WhisperSetting).void }
    def initialize(setting)
      @setting = setting
    end

    sig { override.returns(String) }
    def service_name = "Whisper"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # fog's Whisper app sits beside Stream on the LAN, at the address an
    # admin typed into Settings.
    sig { override.returns(T::Boolean) }
    def allow_private_addresses? = true # rubocop:disable Stream/NoUnreviewedPrivateEgress

    sig { returns([ T::Boolean, String ]) }
    def test_connection
      path = @setting.api_kind_enum == WhisperSetting::ApiKind::AsrWebservice ? "/docs" : "/v1/models"
      answer_test do
        http_get("#{@setting.url}#{path}", headers: auth_headers)
        "Whisper answered"
      end
    end

    # [language, [{ start:, end:, text: }]]
    sig { params(audio: Pathname).returns([ T.nilable(String), T::Array[T::Hash[Symbol, T.untyped]] ]) }
    def transcribe(audio)
      kind = @setting.api_kind_enum
      response = case kind
      when WhisperSetting::ApiKind::AsrWebservice
        http_post_multipart("#{@setting.url}/asr?task=transcribe&output=json&encode=true", file: audio, filename: audio.basename.to_s,
          content_type: "audio/ogg", part_name: "audio_file", headers: auth_headers, read_timeout: READ_TIMEOUT)
      when WhisperSetting::ApiKind::Openai
        http_post_multipart("#{@setting.url}/v1/audio/transcriptions", file: audio, filename: audio.basename.to_s, content_type: "audio/ogg",
          fields: { "model" => @setting.model.presence || "whisper-1", "response_format" => "verbose_json",
                    "timestamp_granularities[]" => "segment" },
          headers: auth_headers, read_timeout: READ_TIMEOUT)
      else T.absurd(kind)
      end
      data = parse_object(response)
      segments = Array(data["segments"]).filter_map do |segment|
        text = segment["text"].to_s.strip
        { start: segment["start"].to_f, end: segment["end"].to_f, text: text } if text.present?
      end
      [ data["language"].presence, segments ]
    end

    # Mono 16 kHz Opus: what Whisper hears at, a few MB an hour.
    sig { params(file: MediaFile, into: Pathname).void }
    def self.extract_audio(file, into:)
      result = ToolRunner.run([ "ffmpeg", "-hide_banner", "-v", "error", "-nostdin", "-y", "-protocol_whitelist", "file",
                                "-i", "file:#{file.path}", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "libopus", "-b:a", "24k",
                                into.to_s ], timeout: 3600)
      raise Error, "Couldn't extract the audio: #{result.stderr.lines.last.to_s.strip}" unless result.success? && into.file?
    end

    private

    sig { returns(T::Hash[String, String]) }
    def auth_headers
      key = @setting.api_key
      key.present? ? { "Authorization" => "Bearer #{key}" } : {}
    end
  end
end
