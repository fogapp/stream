# typed: strict
# frozen_string_literal: true

module Catalog
  # Scores provider candidates against what a file's name said (PROPOSAL
  # §5.2). A score comes with its reasons so the Needs match queue can show
  # why a candidate lost.
  module Scorer
    extend T::Sig

    # At or above: matched without asking. Below it, a person picks.
    MATCH_THRESHOLD = 0.85
    # Two candidates this close are a coin toss ("Dune" with no year).
    AMBIGUITY_MARGIN = 0.05
    # A coin toss TMDB's audience has already called: when one of the tied
    # candidates has this many times the votes of every other ("Shameless"
    # 2011 has 3,517, the 2004 original 161), it's the one people mean.
    LANDSLIDE_RATIO = 4
    # …and at least this many, so 9 votes to 2 stays a person's call.
    LANDSLIDE_MIN_VOTES = 20

    class Scored < T::Struct
      const :tmdb_id, Integer
      const :title, String
      const :year, T.nilable(Integer)
      const :overview, T.nilable(String)
      const :poster_path, T.nilable(String)
      const :popularity, Float
      const :vote_count, Integer
      const :score, Float
      const :reasons, T::Array[String]

      extend T::Sig

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        { "tmdb_id" => tmdb_id, "title" => title, "year" => year, "overview" => overview&.truncate(300),
          "poster_path" => poster_path, "vote_count" => vote_count, "score" => score.round(3), "reasons" => reasons }
      end
    end

    class Verdict < T::Struct
      const :state, Matchable::State
      const :best, T.nilable(Scored)
      const :candidates, T::Array[Scored]
    end

    sig do
      params(results: T::Array[T::Hash[String, T.untyped]], title: String, year: T.nilable(Integer),
        date_key: String, title_keys: T::Array[String]).returns(Verdict)
    end
    def self.judge(results, title:, year:, date_key:, title_keys:)
      scored = results.first(10).map { |result| score(result, title: title, year: year, date_key: date_key, title_keys: title_keys) }
        .sort_by { |candidate| [ -candidate.score, -candidate.popularity ] }
      best = scored.first
      return Verdict.new(state: Matchable::State::Unmatched, best: nil, candidates: []) if best.nil?

      runner_up = scored[1]
      ambiguous = runner_up && (best.score - runner_up.score) < AMBIGUITY_MARGIN
      if ambiguous && best.score >= MATCH_THRESHOLD
        favorite = landslide(scored.select { |candidate| best.score - candidate.score < AMBIGUITY_MARGIN })
        if favorite
          return Verdict.new(state: Matchable::State::Matched, best: favorite,
            candidates: [ favorite, *scored.reject { |candidate| candidate.equal?(favorite) } ].first(5))
        end
      end
      state =
        if best.score >= MATCH_THRESHOLD && !ambiguous then Matchable::State::Matched
        elsif best.score >= 0.4 then Matchable::State::NeedsReview
        else Matchable::State::Unmatched
        end
      Verdict.new(state: state, best: best, candidates: scored.first(5))
    end

    # The tied candidate with a landslide of TMDB votes over the rest, carrying
    # that as a reason; nil when the vote is close.
    sig { params(tied: T::Array[Scored]).returns(T.nilable(Scored)) }
    def self.landslide(tied)
      favorite, *rest = tied.sort_by { |candidate| -candidate.vote_count }
      return nil if favorite.nil? || rest.empty? || favorite.vote_count < LANDSLIDE_MIN_VOTES

      closest = T.must(rest.first)
      return nil if favorite.vote_count < LANDSLIDE_RATIO * closest.vote_count

      reason = "#{favorite.vote_count.to_fs(:delimited)} TMDB votes to #{closest.vote_count.to_fs(:delimited)} " \
               "for #{closest.title} (#{closest.year || '?'})"
      favorite.with(reasons: [ *favorite.reasons, reason ])
    end
    private_class_method :landslide

    sig do
      params(result: T::Hash[String, T.untyped], title: String, year: T.nilable(Integer), date_key: String,
        title_keys: T::Array[String]).returns(Scored)
    end
    def self.score(result, title:, year:, date_key:, title_keys:)
      reasons = []
      names = title_keys.filter_map { |key| result[key].presence }
      title_score = names.map { |name| similarity(title, name.to_s) }.max || 0.0
      reasons << (title_score >= 0.999 ? "title matches" : "title #{(title_score * 100).round}% similar")

      result_year = result[date_key].to_s[0, 4].presence&.to_i
      year_reason, year_score = year_fit(year, result_year)
      reasons << year_reason

      Scored.new(
        tmdb_id: result.fetch("id").to_i, title: names.first.to_s, year: result_year,
        overview: result["overview"].presence, poster_path: result["poster_path"],
        popularity: result["popularity"].to_f, vote_count: result["vote_count"].to_i, score: (title_score * 0.7) + (year_score * 0.3), reasons: reasons
      )
    end

    sig { params(year: T.nilable(Integer), result_year: T.nilable(Integer)).returns([ String, Float ]) }
    def self.year_fit(year, result_year)
      return [ "no year in the file name", 0.6 ] if year.nil?
      return [ "provider has no date", 0.5 ] if result_year.nil?
      return [ "year matches", 1.0 ] if result_year == year
      return [ "year off by one", 0.8 ] if (result_year - year).abs == 1

      [ "year #{result_year}, file says #{year}", 0.0 ]
    end
    private_class_method :year_fit

    # Dice coefficient over character bigrams of the normalized titles:
    # forgiving of punctuation and small typos, strict about different words.
    sig { params(left: String, right: String).returns(Float) }
    def self.similarity(left, right)
      a = Media::NameParser.normalize(left)
      b = Media::NameParser.normalize(right)
      return 1.0 if a == b
      return 0.0 if a.length < 2 || b.length < 2

      pairs_a = bigrams(a)
      pairs_b = bigrams(b)
      counts_b = pairs_b.tally
      overlap = pairs_a.tally.sum { |pair, count| [ count, counts_b.fetch(pair, 0) ].min }
      (2.0 * overlap) / (pairs_a.size + pairs_b.size)
    end

    sig { params(text: String).returns(T::Array[String]) }
    def self.bigrams(text) = text.chars.each_cons(2).map(&:join)
    private_class_method :bigrams
  end
end
