# typed: strict
# frozen_string_literal: true

module Catalog
  # Files a probed media file under the movie or episode it holds
  # (PROPOSAL §5.2). The title is found locally first — the same folder, the
  # same parsed name, the same id — so a second copy of a film or the tenth
  # episode of a show never asks TMDB again. Without a TMDB key everything
  # still lands, unmatched, under its parsed name: browsable and playable.
  class FileMatcher
    extend T::Sig

    class Unplaceable < StandardError; end

    sig { params(media_file: MediaFile).void }
    def initialize(media_file)
      @file = media_file
      @library = T.let(media_file.library || raise(ActiveRecord::RecordNotFound), Library)
      @client = T.let(Tmdb::Client.for(household, language: @library.metadata_language), T.nilable(Tmdb::Client))
    end

    sig { void }
    def call
      AnalysisRun.track(@file, AnalysisRun::Step::Match, tool_version: @client ? "tmdb" : "filename") do
        parsed = Media::NameParser.parse(relative_path, @library.kind_enum)
        kind = parsed.kind
        case kind
        when Media::NameParser::Kind::Movie then file_movie(parsed)
        when Media::NameParser::Kind::Episode then file_episode(parsed)
        when Media::NameParser::Kind::Extra then file_extra(parsed)
        when Media::NameParser::Kind::Clip then ClipMatcher.new(@file, @library, parsed).call
        when Media::NameParser::Kind::Video
          root = @library.root_for(@file.path)
          folder = root && parsed.show_folder.present? ? File.join(root, parsed.show_folder.to_s) : nil
          VideoMatcher.new(@file, @library, parsed, folder).call
        else T.absurd(kind)
        end
      end
    end

    private

    sig { returns(Household) }
    def household = T.must(Household.find_by(id: @file.household_id))

    sig { returns(String) }
    def relative_path
      root = @library.root_for(@file.path) || @library.roots.find { |candidate| @file.path.start_with?("#{candidate}/") }
      root ? @file.path.delete_prefix(root).delete_prefix("/") : File.basename(@file.path)
    end

    sig { params(parsed: Media::NameParser::Parsed).void }
    def file_movie(parsed)
      movie = existing_movie(parsed) || Movie.create!(household_id: @file.household_id, library: @library,
        title: parsed.title, year: parsed.year, tmdb_id: nil, imdb_id: parsed.imdb_id)
      client = @client
      if client && movie.match_state_enum != Matchable::State::Matched
        hints = TitleMatcher::Hints.new(title: parsed.title, year: parsed.year, tmdb_id: parsed.tmdb_id,
          imdb_id: parsed.imdb_id)
        link(movie, parsed.edition) { TitleMatcher.new(client).match_movie(movie, hints) }
        return
      end
      link(movie, parsed.edition)
    end

    # An extra sits in its title's folder ("Heat (1995)/Heat-trailer.mkv")
    # or a conventional subfolder of it ("Heat (1995)/Featurettes/…"); in a
    # show, a season's folder makes it that season's.
    sig { params(parsed: Media::NameParser::Parsed).void }
    def file_extra(parsed)
      Edition.where(media_file: @file).delete_all
      extra = Extra.find_or_initialize_by(media_file: @file)
      extra.assign_attributes(household_id: @file.household_id, kind: parsed.extra_kind || Extra::Kind::Other.serialize,
        title: parsed.title.presence || File.basename(@file.filename, ".*"))
      extra.owner = extra_owner(parsed)
      extra.save!
      SyncArtworkJob.perform_later("Extra", extra.id)
    end

    sig { params(parsed: Media::NameParser::Parsed).returns(T.nilable(T.any(Movie, Show, Season))) }
    def extra_owner(parsed)
      folder = self.class.title_folder(@file.path)
      if @library.kind_enum == Library::Kind::Shows
        show = filed_show(parsed.show_folder.to_s)
        season_number = File.basename(folder)[Media::NameParser::SEASON_FOLDER, 1]
        return show&.seasons&.find_by(season_number: season_number.to_i) || show if season_number

        return show
      end
      named = Media::NameParser.normalize(parsed.title)
      # Loose in a library's root, only the name can say whose it is.
      return named_movie(Movie.where(library_id: @library.id), named) if @library.roots.include?(folder)

      beside = MediaFile.where(library_id: @library.id).where("path LIKE ?", "#{MediaFile.sanitize_sql_like(folder)}/%")
        .where.not(id: @file.id).where.missing(:extra)
      movies = Movie.where(id: Edition.where(media_file: beside, playable_type: "Movie").select(:playable_id)).order(:sort_title).to_a
      movies.find { |movie| Media::NameParser.normalize(movie.title) == named } || movies.first
    end

    # The folder an extra belongs to: its own, or the one above a
    # "Featurettes"-style folder.
    sig { params(path: String).returns(String) }
    def self.title_folder(path)
      folder = File.dirname(path)
      Media::NameParser::EXTRA_FOLDERS.key?(File.basename(folder).downcase) ? File.dirname(folder) : folder
    end

    # Extras found before their title: claim the ones beside it.
    sig { params(owner: T.any(Movie, Show), folder: String).void }
    def adopt_extras(owner, folder)
      Extra.where(owner_id: nil).joins(:media_file)
        .where("media_files.path LIKE ?", "#{MediaFile.sanitize_sql_like(folder)}/%").find_each do |extra|
        file = extra.media_file
        next if file.nil?

        within = self.class.title_folder(file.path)
        if owner.is_a?(Show)
          season_number = File.basename(within)[Media::NameParser::SEASON_FOLDER, 1]
          extra.update!(owner: (season_number && owner.seasons.find_by(season_number: season_number.to_i)) || owner)
        elsif within == folder && (!@library.roots.include?(folder) ||
              Media::NameParser.normalize(extra.title) == Media::NameParser.normalize(owner.title))
          extra.update!(owner: owner)
        end
      end
    end

    # The file joins the movie before matching, so a match that merges this
    # movie into an existing one carries the file along.
    sig do
      params(movie: Movie, edition_name: T.nilable(String), matching: T.nilable(T.proc.void)).returns(Movie)
    end
    def link(movie, edition_name, &matching)
      Edition.where(media_file: @file).where.not(playable: movie).delete_all
      edition = Edition.find_or_initialize_by(media_file: @file, playable: movie)
      edition.update!(name: edition_name || resolution_label)
      Extra.where(media_file: @file).delete_all
      matching&.call
      adopt_extras(movie.reload, File.dirname(@file.path)) if Movie.exists?(movie.id)
      Artworks.enqueue_playable(movie) if Movie.exists?(movie.id)
      movie
    end

    sig { params(parsed: Media::NameParser::Parsed).returns(T.nilable(Movie)) }
    def existing_movie(parsed)
      current = Edition.find_by(media_file: @file, playable_type: "Movie")&.playable
      return current if current.is_a?(Movie)

      scope = Movie.unscoped.where(library_id: @library.id)
      found = (parsed.tmdb_id && scope.find_by(tmdb_id: parsed.tmdb_id)) || (parsed.imdb_id && scope.find_by(imdb_id: parsed.imdb_id))
      return found if found

      # Two versions of one film parse to the same name ("Heat (1995)/Heat
      # 4K.mkv" and "Heat (1995)/Heat (1995).mkv" both read as Heat, 1995).
      # Folder siblings are not enough on their own: "Alien Collection/"
      # holds four different films.
      named_movie(scope.where(year: parsed.year), Media::NameParser.normalize(parsed.title))
    end

    # The film in `scope` whose title normalizes to `named`: by its
    # normalized_title, or for a row written without one (by a replica on
    # older code), by its title compared as before.
    sig { params(scope: T.untyped, named: String).returns(T.nilable(Movie)) }
    def named_movie(scope, named)
      scope.where(normalized_title: named).take ||
        scope.where(normalized_title: nil).find { |movie| Media::NameParser.normalize(movie.title) == named }
    end

    sig { params(parsed: Media::NameParser::Parsed).void }
    def file_episode(parsed)
      show = find_or_create_show(parsed)
      season_number = parsed.season
      if season_number.nil? && parsed.air_date.nil?
        raise Unplaceable, "Couldn't read a season and episode number from #{@file.filename}"
      end

      episodes = place_episodes(show, parsed)
      raise Unplaceable, "Couldn't place #{@file.filename} in #{show.title}" if episodes.empty?

      Edition.where(media_file: @file).where.not(playable_type: "Episode", playable_id: episodes.map(&:id)).delete_all
      episodes.each do |episode|
        Edition.find_or_create_by!(media_file: @file, playable: episode) { |edition| edition.name = resolution_label }
        Artworks.enqueue_playable(episode)
      end
      Markers::Detector.detect_later(show, T.must(episodes.first).season_number, priority: Media::AnalysisPriority.for(@file))
      NotifyArrivalsJob.set(wait: NotifyArrivalsJob::WAIT).perform_later("show", show.id)
    end

    sig { params(parsed: Media::NameParser::Parsed).returns(Show) }
    def find_or_create_show(parsed)
      folder = parsed.show_folder || parsed.title
      show = filed_show(folder) || begin
        Show.create!(household_id: @file.household_id, library: @library, folder: folder, title: parsed.title,
          year: parsed.year, tvdb_id: parsed.tvdb_id, imdb_id: parsed.imdb_id)
      rescue ActiveRecord::RecordNotUnique
        T.must(filed_show(folder))
      end
      root = @library.root_for(@file.path)
      adopt_extras(show, File.join(root, folder)) if root
      client = @client
      if client && show.match_state_enum != Matchable::State::Matched
        TitleMatcher.new(client).match_show(show, TitleMatcher::Hints.new(title: parsed.title, year: parsed.year,
          tmdb_id: parsed.tmdb_id, imdb_id: parsed.imdb_id, tvdb_id: parsed.tvdb_id))
        # A match can fold this folder into a show that already had the title.
        show = T.must(filed_show(folder))
      end
      show
    end

    sig { params(folder: String).returns(T.nilable(Show)) }
    def filed_show(folder)
      ShowFolder.unscoped.find_by(library_id: @library.id, folder: folder)&.show
    end

    sig { params(show: Show, parsed: Media::NameParser::Parsed).returns(T::Array[Episode]) }
    def place_episodes(show, parsed)
      season_number = parsed.season
      fetch_season(show, season_number) if season_number

      air_date = parsed.air_date
      if parsed.episodes.empty? && air_date
        by_date = show.episodes.find_by(air_date: air_date)
        return [ by_date ] if by_date

        season = season_row(show, season_number || air_date.year)
        return [ show.episodes.create!(season: season, season_number: season.season_number, episode_number: nil,
          air_date: air_date, title: File.basename(@file.filename, ".*")) ]
      end

      season = season_row(show, T.must(season_number))
      parsed.episodes.map do |number|
        show.episodes.find_by(season_number: season.season_number, episode_number: number) ||
          show.episodes.create!(season: season, season_number: season.season_number, episode_number: number)
      end
    end

    # Once per show and season: a season already filled from TMDB is not
    # asked again (metadata refresh is its own job).
    sig { params(show: Show, number: Integer).void }
    def fetch_season(show, number)
      client = @client
      tmdb_id = show.tmdb_id
      return if client.nil? || tmdb_id.nil? || show.match_state_enum != Matchable::State::Matched

      existing = show.seasons.find_by(season_number: number)
      return if existing && existing.episodes.where.not(tmdb_id: nil).exists?

      Metadata.apply_season(show, client.season(tmdb_id, number))
    rescue Tmdb::Client::Error => e
      # A rate limit or a refused key isn't about this season: up to the
      # job's retry_on, as before.
      raise if e.is_a?(UpstreamHttpClient::RateLimitError) || e.is_a?(UpstreamHttpClient::AuthError)

      # A season TMDB doesn't know (a special, a fan numbering) still plays.
      Activity.record(source: "metadata", event: "season.fetch_failed", severity: Activity::Severity::Warn,
        subject: show, household_id: show.household_id, summary: "#{show.title} season #{number}: #{e.message}")
    end

    sig { params(show: Show, number: Integer).returns(Season) }
    def season_row(show, number)
      show.seasons.find_or_create_by!(season_number: number)
    rescue ActiveRecord::RecordNotUnique
      show.seasons.find_by!(season_number: number)
    end

    sig { returns(T.nilable(String)) }
    def resolution_label
      video = @file.primary_video
      height = video&.height
      return nil if height.nil?

      base = if height >= 2000 then "4K" elsif height >= 1000 then "1080p" elsif height >= 700 then "720p" else "SD" end
      video&.hdr_format.present? ? "#{base} HDR" : base
    end
  end
end
