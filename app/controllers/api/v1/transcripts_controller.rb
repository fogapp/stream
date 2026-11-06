# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # A title's transcript (PROPOSAL §5.5), for the watch page's
    # "Transcript" panel: every line with its time.
    class TranscriptsController < BaseController
      sig { void }
      def show
        playable = find_playable
        file = playable.playable_files.joins(:transcript).order(size: :desc).first
        transcript = file&.transcript
        return render json: { available: false, lines: [] } if transcript.nil?

        render json: {
          available: true, source: transcript.source_enum.serialize, language: transcript.language,
          lines: transcript.transcript_lines.pluck(:start_seconds, :end_seconds, :text).map { |start, finish, text| { start: start, end: finish, text: text } }
        }
      end

      private

      sig { returns(T.any(Movie, Episode, Video)) }
      def find_playable
        T.cast(Viewing::Playables.find!(params.require(:playable_type), params.require(:playable_id), only: %w[movie episode video]),
          T.any(Movie, Episode, Video))
      end
    end
  end
end
