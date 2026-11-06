# typed: strict
# frozen_string_literal: true

# Speech to text for one video (PROPOSAL §5.5). One at a time for the
# whole server: Whisper on a CPU is slow, and it's shared with Hub.
class TranscribeWithWhisperJob < ApplicationJob
  extend T::Sig

  queue_as :heavy
  limits_concurrency to: 1, key: ->(_media_file_id) { "whisper" }, duration: 3.hours
  retry_on Transcripts::WhisperClient::Error, wait: 30.minutes, attempts: 3

  sig { params(media_file_id: String).void }
  def perform(media_file_id)
    file = MediaFile.unscoped.find_by(id: media_file_id)
    setting = file && WhisperSetting.unscoped.find_by(household_id: file.household_id)
    return if file.nil? || setting.nil? || !setting.enabled

    AnalysisRun.track(file, AnalysisRun::Step::Transcript, tool_version: "whisper") do
      Tempfile.create([ "whisper", ".ogg" ]) do |audio|
        path = Pathname.new(audio.path)
        Transcripts::WhisperClient.extract_audio(file, into: path)
        language, lines = Transcripts::WhisperClient.new(setting).transcribe(path)
        Transcripts::Builder.new(file).store(Transcript::Source::Whisper, language, nil, lines)
      end
    end
  end
end
