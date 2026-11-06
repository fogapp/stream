# typed: strict
# frozen_string_literal: true

module Catalog
  # Decides which TMDB title a movie or show is (PROPOSAL §5.2): an id hint
  # in the folder name wins outright; otherwise a scored search, matched only
  # when the best candidate is clearly best. Everything else goes to Needs
  # match with its candidates and reasons, never to a guess.
  class TitleMatcher
    extend T::Sig

    class Hints < T::Struct
      const :title, String
      const :year, T.nilable(Integer), default: nil
      const :tmdb_id, T.nilable(Integer), default: nil
      const :imdb_id, T.nilable(String), default: nil
      const :tvdb_id, T.nilable(Integer), default: nil
    end

    sig { params(client: Tmdb::Client).void }
    def initialize(client)
      @client = client
    end

    sig { params(movie: Movie, hints: Hints).void }
    def match_movie(movie, hints)
      id = hints.tmdb_id || find_by_external(hints.imdb_id, "imdb_id", "movie_results")
      if id
        choose_movie(movie, id, reason: "id in the folder name")
        return
      end

      verdict = best_verdict(Library::Kind::Movies, hints.title, hints.year)
      settle(movie, verdict) { |best| choose_movie(movie, best.tmdb_id, reason: best.reasons.join(", "), score: best.score) }
    end

    sig { params(show: Show, hints: Hints).void }
    def match_show(show, hints)
      id = hints.tmdb_id ||
        find_by_external(hints.tvdb_id&.to_s, "tvdb_id", "tv_results") ||
        find_by_external(hints.imdb_id, "imdb_id", "tv_results")
      # A title a person said this isn't ("Not this show") is never chosen
      # for it again on its own.
      rejected = Array(show.match_reasons["rejected"]).map(&:to_i)
      if id && rejected.exclude?(id)
        choose_show(show, id, reason: "id in the folder name")
        return
      end

      title = hints.title.sub(/\s*\((US|UK|AU|NZ|CA)\)\z/i, "")
      verdict = without(best_verdict(Library::Kind::Shows, title, hints.year), rejected)
      # The best fit is the title a person rejected: what they left stands.
      return if verdict.nil?

      settle(show, verdict) { |best| choose_show(show, best.tmdb_id, reason: best.reasons.join(", "), score: best.score) }
    end

    # A person's pick from Fix match, or a confident automatic one.
    sig { params(movie: Movie, tmdb_id: Integer, reason: String, score: Float).returns(Movie) }
    def choose_movie(movie, tmdb_id, reason:, score: 1.0)
      existing = Movie.unscoped.where(library_id: movie.library_id, tmdb_id: tmdb_id).where.not(id: movie.id).first
      target = existing ? merge_into(movie, existing) : movie
      Metadata.apply_movie(target, @client.movie(tmdb_id), region: region_for(target.library))
      record_match(target, reason, score)
      target
    end

    sig { params(show: Show, tmdb_id: Integer, reason: String, score: Float).returns(Show) }
    def choose_show(show, tmdb_id, reason:, score: 1.0)
      details = @client.show(tmdb_id)
      target = claim_show(show, tmdb_id)
      Metadata.apply_show(target, details, region: region_for(target.library))
      record_match(target, reason, score)
      target
    end

    # A search for Fix match: the same scoring, so the list explains itself.
    sig { params(kind: Library::Kind, query: String, year: T.nilable(Integer)).returns(T::Array[Scorer::Scored]) }
    def search(kind, query, year: nil)
      case kind
      when Library::Kind::Movies, Library::Kind::Shows then scored(kind, query, year, search_year: year).candidates
      when Library::Kind::Channels, Library::Kind::HomeVideos, Library::Kind::Live then []
      else T.absurd(kind)
      end
    end

    private

    # Searched with the year, and when that doesn't settle it, without: a
    # year-less search can miss an old film that a year-filtered one would
    # find; a year-filtered one can miss a film released a year off.
    sig { params(kind: Library::Kind, title: String, year: T.nilable(Integer)).returns(Scorer::Verdict) }
    def best_verdict(kind, title, year)
      verdict = scored(kind, title, year, search_year: year)
      return verdict if verdict.state == Matchable::State::Matched || year.nil?

      broader = scored(kind, title, year, search_year: nil)
      (broader.best&.score || 0) > (verdict.best&.score || 0) ? broader : verdict
    end

    # TMDB's results for a film or a show, judged against the file's title.
    sig { params(kind: Library::Kind, title: String, year: T.nilable(Integer), search_year: T.nilable(Integer)).returns(Scorer::Verdict) }
    def scored(kind, title, year, search_year:)
      movies = kind == Library::Kind::Movies
      results = movies ? @client.search_movies(title, year: search_year) : @client.search_shows(title, year: search_year)
      Scorer.judge(results, title: title, year: year, date_key: movies ? "release_date" : "first_air_date",
        title_keys: movies ? %w[title original_title] : %w[name original_name])
    end

    sig { params(verdict: Scorer::Verdict, rejected: T::Array[Integer]).returns(T.nilable(Scorer::Verdict)) }
    def without(verdict, rejected)
      return verdict if rejected.empty?
      return nil if rejected.include?(verdict.best&.tmdb_id)

      Scorer::Verdict.new(state: verdict.state, best: verdict.best,
        candidates: verdict.candidates.reject { |candidate| rejected.include?(candidate.tmdb_id) })
    end

    sig { params(id: T.nilable(String), source: String, key: String).returns(T.nilable(Integer)) }
    def find_by_external(id, source, key)
      return nil if id.blank?

      Array(@client.find(id, source: source)[key]).first&.dig("id")&.to_i
    end

    sig do
      params(title: T.any(Movie, Show), verdict: Scorer::Verdict,
        choose: T.proc.params(best: Scorer::Scored).void).void
    end
    def settle(title, verdict, &choose)
      best = verdict.best
      if verdict.state == Matchable::State::Matched && best
        choose.call(best)
        return
      end

      title.update!(match_state: verdict.state.serialize, match_score: best&.score,
        match_candidates: verdict.candidates.map(&:to_h),
        match_reasons: title.match_reasons.slice("rejected").merge("summary" => summarize(verdict)))
    end

    sig { params(verdict: Scorer::Verdict).returns(String) }
    def summarize(verdict)
      best = verdict.best
      return "TMDB found nothing for this name." if best.nil?

      runner_up = verdict.candidates[1]
      if runner_up && best.score >= Scorer::MATCH_THRESHOLD
        "#{best.title} (#{best.year || '?'}) and #{runner_up.title} (#{runner_up.year || '?'}) fit equally well."
      else
        "Best guess #{best.title} (#{best.year || '?'}) is only #{(best.score * 100).round}% likely: #{best.reasons.join(', ')}."
      end
    end

    sig { params(title: T.any(Movie, Show), reason: String, score: Float).void }
    def record_match(title, reason, score)
      title.update!(match_state: Matchable::State::Matched.serialize, match_score: score, match_candidates: [],
        match_reasons: title.match_reasons.slice("rejected").merge("summary" => "Matched: #{reason}."))
    end

    # Two files of the same film matched separately (a 4K copy and a 1080p
    # one): the later title's editions join the earlier one, and it goes.
    sig { params(source: Movie, target: Movie).returns(Movie) }
    def merge_into(source, target)
      Movie.transaction do
        Edition.where(playable: source).find_each do |edition|
          if Edition.exists?(media_file_id: edition.media_file_id, playable: target)
            edition.destroy!
          else
            edition.update!(playable: target)
          end
        end
        Extra.where(owner: source).update_all(owner_id: target.id) # rubocop:disable Rails/SkipsModelValidations
        source.reload.destroy!
      end
      target
    end

    # A second folder of a show the library already has ("Bluey (2018)"
    # beside "Bluey") joins it rather than standing beside it. Under a lock
    # on the title, so two folders matched at once can't both keep it.
    sig { params(show: Show, tmdb_id: Integer).returns(Show) }
    def claim_show(show, tmdb_id)
      Show.transaction do
        connection = Show.connection
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote("show:#{show.library_id}:#{tmdb_id}")}))")
        existing = Show.unscoped.where(library_id: show.library_id, tmdb_id: tmdb_id).where.not(id: show.id)
          .order(:created_at).first
        next ShowMerge.call(show, existing) if existing

        show.update!(tmdb_id: tmdb_id)
        show
      end
    end

    sig { params(library: T.nilable(Library)).returns(String) }
    def region_for(library)
      library&.metadata_language.to_s.split("-")[1] || Metadata::DEFAULT_REGION
    end
  end
end
