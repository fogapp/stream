# typed: strict
# frozen_string_literal: true

module Transcripts
  # A file's transcript (PROPOSAL §5.5): from its own text subtitles when it
  # has some — English, not forced, preferring the default — else, for a
  # channel video or a home video, from Whisper if the household has it set up.
  class Builder
    extend T::Sig

    ENGLISH = T.let(%w[en eng en-us en-gb].to_set.freeze, T::Set[String])

    class Outcome < T::Enum
      include ApplicationEnum
      enums do
        FromSubtitles = new("from_subtitles")
        NeedsWhisper = new("needs_whisper")
        Nothing = new("nothing")
        Unchanged = new("unchanged")
      end
    end

    sig { params(file: MediaFile).void }
    def initialize(file)
      @file = file
    end

    sig { returns(Outcome) }
    def call
      track = best_track
      if track
        existing = @file.transcript
        return Outcome::Unchanged if existing && existing.source_enum == Transcript::Source::Subtitles && existing.track_id == track.id

        lines = Vtt.parse(Subtitles::Extractor.fetch(@file, track, "vtt").read)
        return Outcome::Nothing if lines.empty?

        store(Transcript::Source::Subtitles, track.language, track.id, lines)
        return Outcome::FromSubtitles
      end
      return Outcome::Unchanged if @file.transcript&.source_enum == Transcript::Source::Whisper
      return Outcome::NeedsWhisper if whisper_wanted?

      Outcome::Nothing
    end

    sig { params(source: Transcript::Source, language: T.nilable(String), track_id: T.nilable(String), lines: T::Array[T::Hash[Symbol, T.untyped]]).void }
    def store(source, language, track_id, lines)
      transcript = @file.transcript || Transcript.new(media_file: @file)
      transcript.update!(source: source.serialize, language: language, track_id: track_id)
      transcript.replace_lines(lines)
    end

    private

    sig { returns(T.nilable(Subtitles::Tracks::Track)) }
    def best_track
      text = Subtitles::Tracks.for(@file).select { |track| text?(track.format) && !track.forced && !track.generated }
      english = text.select { |track| ENGLISH.include?(track.language.to_s.downcase) }
      pool = english.any? ? english : text.select { |track| track.language.nil? }
      pool.min_by { |track| [ track.default ? 0 : 1, track.hearing_impaired ? 1 : 0 ] }
    end

    # Only text becomes words: PGS, DVD and DVB tracks are pictures, and
    # ffmpeg refuses to turn a picture into WebVTT.
    sig { params(format: Subtitles::Tracks::Format).returns(T::Boolean) }
    def text?(format)
      case format
      when Subtitles::Tracks::Format::Vtt, Subtitles::Tracks::Format::Ass then true
      when Subtitles::Tracks::Format::Pgs, Subtitles::Tracks::Format::Burn then false
      else T.absurd(format)
      end
    end

    sig { returns(T::Boolean) }
    def whisper_wanted?
      setting = WhisperSetting.unscoped.find_by(household_id: @file.household_id)
      return false if setting.nil? || !setting.enabled

      Edition.exists?(media_file_id: @file.id, playable_type: %w[Video Clip])
    end
  end
end
