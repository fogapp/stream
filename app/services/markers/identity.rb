# typed: strict
# frozen_string_literal: true

module Markers
  # Does an episode sound like its show? (Hook's GET /episodes/:id/identity.)
  # The show's theme, as other episodes' detected intros, listened for in
  # this episode's opening minutes: heard in most of them is a match; a show
  # whose episodes share a theme that this file's opening doesn't contain is
  # a mismatch — a file filed under the wrong show. Only what analysis has
  # already left (intro markers, opening fingerprints) is read; with too
  # little of it the answer is unknown, never a wait for analysis.
  module Identity
    extend T::Sig

    class Verdict < T::Enum
      include ApplicationEnum
      enums do
        Match = new("match")
        Mismatch = new("mismatch")
        Unknown = new("unknown")
      end
    end

    class Result < T::Struct
      const :intro, Verdict
      const :confidence, Float
      # How many other episodes' intros it was compared with.
      const :compared, Integer
    end

    # Other episodes listened against: the nearest first.
    REFERENCES = 4
    MIN_REFERENCES = 2
    # How much of a reference's intro an opening must contain to have it.
    COVER = 0.6
    MIN_HEARD_SECONDS = 5.0

    class Reference < T::Struct
      const :intro, Marker
      const :print, AudioFingerprint
    end

    sig { params(episode: Episode).returns(Result) }
    def self.for(episode)
      file = episode.best_file
      mine = file && AudioFingerprint.find_by(media_file: file, segment: AudioFingerprint::Segment::Head.serialize)
      return unknown if file.nil? || mine.nil?

      references = references(episode, file)
      return unknown(references.size) if references.size < MIN_REFERENCES

      # A show with a theme: the first reference's intro heard in the others.
      first = T.must(references.first)
      consistency = references.drop(1).count { |other| heard(other.print, first) }.to_f / (references.size - 1)
      return unknown(references.size) if consistency < 0.5

      found = references.filter_map { |reference| heard(mine, reference) }
      share = found.size.to_f / references.size
      if share >= 0.5
        Result.new(intro: Verdict::Match, confidence: (share * found.sum(0.0) / found.size).round(3).to_f, compared: references.size)
      elsif found.empty?
        # More references that agree among themselves, more certainty.
        confidence = (consistency * (0.6 + (0.1 * references.size))).clamp(0.0, 0.95)
        Result.new(intro: Verdict::Mismatch, confidence: confidence.round(3).to_f, compared: references.size)
      else
        unknown(references.size)
      end
    end

    sig { params(compared: Integer).returns(Result) }
    def self.unknown(compared = 0) = Result.new(intro: Verdict::Unknown, confidence: 0.0, compared: compared)
    private_class_method :unknown

    # Other episodes of the show with a readable file whose intro is known
    # and whose opening was fingerprinted: same season first, then nearest.
    sig { params(episode: Episode, file: MediaFile).returns(T::Array[Reference]) }
    def self.references(episode, file)
      others = Episode.where(show_id: episode.show_id).where.not(id: episode.id).pluck(:id, :season_number, :episode_number)
        .to_h { |id, season, number| [ id, [ season, number.to_i ] ] }
      pairs = Edition.readable.where(playable_type: "Episode", playable_id: others.keys).where.not(media_file_id: file.id)
        .pluck(:playable_id, :media_file_id)
      file_ids = pairs.map(&:last)
      intros = Marker.where(media_file_id: file_ids, kind: Marker::Kind::Intro.serialize).index_by(&:media_file_id)
      printed = AudioFingerprint.where(media_file_id: file_ids, segment: AudioFingerprint::Segment::Head.serialize).pluck(:media_file_id).to_set
      season = episode.season_number
      number = episode.episode_number.to_i
      chosen = pairs.select { |_, file_id| intros.key?(file_id) && printed.include?(file_id) }
        .sort_by do |episode_id, _|
          other_season, other_number = others.fetch(episode_id)
          [ (other_season - season).abs, (other_number - number).abs ]
        end
        .uniq(&:first).first(REFERENCES)
      prints = AudioFingerprint.where(media_file_id: chosen.map(&:last), segment: AudioFingerprint::Segment::Head.serialize).index_by(&:media_file_id)
      chosen.filter_map do |_, file_id|
        print = prints[file_id]
        print && Reference.new(intro: intros.fetch(file_id), print: print)
      end
    end
    private_class_method :references

    # How surely an opening contains the reference's intro, or nil.
    sig { params(opening: AudioFingerprint, reference: Reference).returns(T.nilable(Float)) }
    def self.heard(opening, reference)
      theme = theme_points(reference)
      return nil if theme.empty?

      length = theme.size * Matcher::SECONDS_PER_POINT
      match = Matcher.best(opening.points, theme, min: [ length * COVER, MIN_HEARD_SECONDS ].max)
      match&.confidence
    end
    private_class_method :heard

    # The reference's intro, cut from its opening fingerprint.
    sig { params(reference: Reference).returns(T::Array[Integer]) }
    def self.theme_points(reference)
      offset = reference.print.offset_seconds
      from = ((reference.intro.start_seconds - offset) / Matcher::SECONDS_PER_POINT).floor
      to = ((reference.intro.end_seconds - offset) / Matcher::SECONDS_PER_POINT).ceil
      return [] if from.negative? || to <= from

      reference.print.points[from...to] || []
    end
    private_class_method :theme_points
  end
end
