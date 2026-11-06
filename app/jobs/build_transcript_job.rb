# typed: strict
# frozen_string_literal: true

# A file's transcript from its subtitles (PROPOSAL §5.5) — quick — and,
# for a channel video with none, a Whisper job, which isn't.
class BuildTranscriptJob < ApplicationJob
  extend T::Sig

  queue_as :analyze
  limits_concurrency to: 1, key: ->(media_file_id) { "transcript:#{media_file_id}" }

  sig { params(media_file_id: String).void }
  def perform(media_file_id)
    file = MediaFile.unscoped.includes(:media_streams).find_by(id: media_file_id)
    return if file.nil? || file.state_enum != MediaFile::State::Probed

    outcome = T.let(nil, T.nilable(Transcripts::Builder::Outcome))
    AnalysisRun.track(file, AnalysisRun::Step::Transcript, tool_version: "subtitles") do
      outcome = Transcripts::Builder.new(file).call
    end
    TranscribeWithWhisperJob.perform_later(file.id) if outcome == Transcripts::Builder::Outcome::NeedsWhisper
  end
end
