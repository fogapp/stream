# typed: strict
# frozen_string_literal: true

# Where transcripts come from when a video has no subtitles (PROPOSAL
# §5.5): fog's Whisper app, or any OpenAI-compatible speech-to-text server.
# Configured in Settings › Integrations, never by env var.
class WhisperSetting < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested

  class ApiKind < T::Enum
    include ApplicationEnum
    enums do
      # onerahmet/openai-whisper-asr-webservice: POST /asr.
      AsrWebservice = new("asr_webservice")
      # POST /v1/audio/transcriptions (speaches, LocalAI, OpenAI).
      Openai = new("openai")
    end
  end

  encrypts :api_key

  attribute :api_kind, ApiKind

  normalizes :url, with: ->(url) { url.strip.chomp("/") }
  validates :url, presence: true, format: { with: %r{\Ahttps?://[^\s]+\z}, message: "must start with http:// or https://" }
end
