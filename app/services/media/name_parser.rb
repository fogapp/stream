# typed: strict
# frozen_string_literal: true

module Media
  # Reads what a file is from where it sits and what it's called
  # (PROPOSAL §5.2). Works on the path relative to its library root, so the
  # folders count as evidence too: "Heat (1995)/heat.1995.1080p.mkv" is a
  # movie called Heat from 1995, and "Severance/Season 2/S02E03.mkv" is an
  # episode of Severance.
  #
  # It only reads names. Deciding which TMDB entry a name means is the
  # matcher's job.
  module NameParser
    extend T::Sig

    class Kind < T::Enum
      include ApplicationEnum
      enums do
        Movie = new("movie")
        Episode = new("episode")
        # A trailer, featurette or other bonus. Never becomes a title of its own.
        Extra = new("extra")
        # One video in a channel folder (PROPOSAL §5.4).
        Video = new("video")
        # A home video (PROPOSAL §4.2).
        Clip = new("clip")
      end
    end

    class Ids < T::Struct
      const :tmdb_id, T.nilable(Integer), default: nil
      const :imdb_id, T.nilable(String), default: nil
      const :tvdb_id, T.nilable(Integer), default: nil
    end

    class Parsed < T::Struct
      const :kind, Kind
      const :title, String
      const :year, T.nilable(Integer), default: nil
      const :season, T.nilable(Integer), default: nil
      const :episodes, T::Array[Integer], default: []
      const :air_date, T.nilable(Date), default: nil
      const :edition, T.nilable(String), default: nil
      const :extra_kind, T.nilable(String), default: nil
      const :tmdb_id, T.nilable(Integer), default: nil
      const :imdb_id, T.nilable(String), default: nil
      const :tvdb_id, T.nilable(Integer), default: nil
      # The folder that identifies a show: its first folder under the root.
      # For a video, the channel's folder.
      const :show_folder, T.nilable(String), default: nil
      # yt-dlp's "Title [dQw4w9WgXcQ]".
      const :youtube_id, T.nilable(String), default: nil
      # A camera's wall clock from a home video's name (no time zone).
      const :wall_clock, T.nilable(Time), default: nil
    end

    # Words that end a title in a scene name: once one appears, the rest is
    # release detail.
    NOISE = T.let(%w[
      2160p 1080p 1080i 720p 576p 480p 4k uhd hdr hdr10 hdr10plus dv dovi sdr
      bluray blu-ray bdrip brrip bdremux remux web web-dl webdl webrip hdtv dvdrip dvd dvdscr hdrip
      x264 x265 h264 h265 hevc avc xvid divx av1 vp9 10bit 8bit
      dts dts-hd dtshd truehd atmos aac ac3 eac3 ddp dd5.1 ddp5.1 flac opus mp3
      proper repack internal limited multi dubbed subbed
      amzn nf dsnp hmax atvp hulu pcok
    ].to_set.freeze, T::Set[String])

    EDITIONS = T.let({
      /director'?s[\s._-]*cut/i => "Director's Cut",
      /extended([\s._-]*(cut|edition))?/i => "Extended",
      /\bunrated\b/i => "Unrated",
      /\btheatrical([\s._-]*cut)?\b/i => "Theatrical",
      /\bfinal[\s._-]*cut\b/i => "Final Cut",
      /\bspecial[\s._-]*edition\b/i => "Special Edition",
      /\bimax\b/i => "IMAX",
      /\bremastered\b/i => "Remastered"
    }.freeze, T::Hash[Regexp, String])

    # Plex's and Jellyfin's extras conventions: a folder of that name, or a
    # "-trailer" style suffix on the file.
    EXTRA_FOLDERS = T.let({
      "trailers" => "trailer", "featurettes" => "featurette", "behind the scenes" => "behind_the_scenes",
      "deleted scenes" => "deleted_scene", "interviews" => "interview", "scenes" => "scene",
      "shorts" => "short", "extras" => "other", "other" => "other", "specials features" => "other"
    }.freeze, T::Hash[String, String])
    EXTRA_SUFFIX = /-(trailer|featurette|behindthescenes|deleted|interview|scene|short|other)\z/i

    YEAR = /(?:\A|[\s.(\[_-])((?:19|20)\d{2})(?:\z|[\s.)\]_-])/
    SXXEYY = /\bs(\d{1,2})[\s._-]*e(\d{1,3})((?:[\s._-]*-?[\s._-]*e\d{1,3})*)/i
    NXNN = /\b(\d{1,2})x(\d{2,3})((?:-\d{1,2}x\d{2,3}|-\d{2,3})*)\b/i
    DATE = /\b((?:19|20)\d{2})[.\-_ ](\d{2})[.\-_ ](\d{2})\b/
    SEASON_FOLDER = /\A(?:season|series|staffel|saison)[\s._-]*(\d{1,4})\z/i

    sig { params(relative_path: String, library_kind: Library::Kind).returns(Parsed) }
    def self.parse(relative_path, library_kind)
      parts = relative_path.split("/").reject(&:empty?)
      filename = parts.pop.to_s
      stem = File.basename(filename, ".*")
      ids = id_hints(relative_path)

      return parse_video(stem, parts) if library_kind == Library::Kind::Channels
      return parse_clip(stem) if library_kind == Library::Kind::HomeVideos
      # Never scanned (PROPOSAL §7.8).
      raise ArgumentError, "A live library has no files" if library_kind == Library::Kind::Live

      extra = extra_kind(stem, parts)
      if extra
        # "Heat (1995)-trailer" is Heat's trailer: the name without the suffix or year.
        named = title_and_year(strip_ids(stem.sub(EXTRA_SUFFIX, ""))).first
        return Parsed.new(kind: Kind::Extra, title: named.presence || clean_title(stem), extra_kind: extra,
          show_folder: library_kind == Library::Kind::Shows ? parts.first : nil, tmdb_id: ids.tmdb_id, imdb_id: ids.imdb_id, tvdb_id: ids.tvdb_id)
      end

      case library_kind
      when Library::Kind::Shows then parse_episode(stem, parts, ids)
      when Library::Kind::Movies then parse_movie(stem, parts, ids)
      else T.absurd(library_kind)
      end
    end

    # Cameras and phones name files by when they were taken:
    # VID_20230405_123456, PXL_20230405_123456789, 2023-04-05 12.34.56,
    # 20230405_123456.
    CAMERA_STAMP = /(?:\A|[_\s-])((?:19|20)\d{2})-?(\d{2})-?(\d{2})[_\sT.-]+(\d{2})[.:-]?(\d{2})[.:-]?(\d{2})/

    sig { params(stem: String).returns(Parsed) }
    def self.parse_clip(stem)
      match = stem.match(CAMERA_STAMP)
      parts = match ? [ match[1].to_i, match[2].to_i, match[3].to_i ] : nil
      date = parts && Date.valid_date?(*parts) ? Date.new(*parts) : nil
      clock = match && date ? [ match[4].to_i, match[5].to_i, match[6].to_i ] : nil
      wall = date && clock && clock[0] < 24 && clock[1] < 60 && clock[2] < 60 ? Time.utc(date.year, date.month, date.day, *clock) : nil
      Parsed.new(kind: Kind::Clip, title: separators_to_spaces(stem).strip.presence || stem, air_date: date, wall_clock: wall)
    end
    private_class_method :parse_clip

    YOUTUBE_ID = /\s*\[([A-Za-z0-9_-]{11})\]\z/
    LEADING_DATE = /\A((?:19|20)\d{2})-?(\d{2})-?(\d{2})\s*[-_.]?\s*/

    # "Channel/20240131 - A Video [dQw4w9WgXcQ].mkv": the channel is the first
    # folder, yt-dlp's id rides in brackets, and a leading date is the upload.
    sig { params(stem: String, folders: T::Array[String]).returns(Parsed) }
    def self.parse_video(stem, folders)
      youtube_id = stem[YOUTUBE_ID, 1]
      name = stem.sub(YOUTUBE_ID, "")
      date = name.match(LEADING_DATE)
      parts = date && [ date[1].to_i, date[2].to_i, date[3].to_i ]
      uploaded = parts && Date.valid_date?(*parts) ? Date.new(*parts) : nil
      name = name.sub(LEADING_DATE, "") if uploaded
      title = name.include?(" ") ? name.strip : separators_to_spaces(name).strip
      Parsed.new(kind: Kind::Video, title: title.presence || stem, air_date: uploaded, youtube_id: youtube_id,
        show_folder: folders.first)
    end
    private_class_method :parse_video

    sig do
      params(stem: String, folders: T::Array[String], ids: Ids).returns(Parsed)
    end
    def self.parse_movie(stem, folders, ids)
      folder = folders.last
      # "Heat (1995)" beats "heat.1995.1080p.bluray": a folder that names a
      # year is the curated name, the file is often the scene name.
      source = folder && folder.match?(YEAR) && !folder.match?(SXXEYY) ? folder : stem
      title, year = title_and_year(strip_ids(source))
      if title.empty? && folder
        title, year = title_and_year(strip_ids(folder))
      end
      Parsed.new(kind: Kind::Movie, title: title.presence || clean_title(stem), year: year,
        edition: edition(stem) || (folder && edition(folder)), tmdb_id: ids.tmdb_id, imdb_id: ids.imdb_id, tvdb_id: ids.tvdb_id)
    end
    private_class_method :parse_movie

    sig do
      params(stem: String, folders: T::Array[String], ids: Ids).returns(Parsed)
    end
    def self.parse_episode(stem, folders, ids)
      show_folder = folders.first
      folder_season = folders.drop(1).filter_map { |folder| season_from_folder(folder) }.last

      season = T.let(nil, T.nilable(Integer))
      episodes = T.let([], T::Array[Integer])
      air_date = T.let(nil, T.nilable(Date))
      before = stem

      if (match = stem.match(SXXEYY))
        season = match[1].to_i
        episodes = [ match[2].to_i ] + match[3].to_s.scan(/e(\d{1,3})/i).flatten.map(&:to_i)
        before = stem[0, match.begin(0)].to_s
      elsif (match = stem.match(NXNN))
        season = match[1].to_i
        episodes = [ match[2].to_i ] + match[3].to_s.scan(/(?:x|-)(\d{2,3})/).flatten.map(&:to_i)
        before = stem[0, match.begin(0)].to_s
      elsif (match = stem.match(DATE))
        air_date = Date.new(match[1].to_i, match[2].to_i, match[3].to_i) rescue nil # rubocop:disable Style/RescueModifier
        before = stem[0, match.begin(0)].to_s
      elsif (match = stem.match(/\b(?:e|ep|episode)[\s._-]*(\d{1,3})\b/i))
        episodes = [ match[1].to_i ]
        before = stem[0, match.begin(0)].to_s
      end
      season ||= folder_season
      season ||= 1 if episodes.any? && folders.size <= 1
      episodes = expand_range(episodes)

      show_source = show_folder || before
      title, year = title_and_year(strip_ids(show_source))
      Parsed.new(kind: Kind::Episode, title: title.presence || clean_title(before.presence || stem), year: year,
        season: season, episodes: episodes, air_date: air_date, show_folder: show_folder, tmdb_id: ids.tmdb_id, imdb_id: ids.imdb_id, tvdb_id: ids.tvdb_id)
    end
    private_class_method :parse_episode

    # "S01E01-E03" names the ends of a run; a file that spans three episodes
    # is episodes 1, 2 and 3.
    sig { params(episodes: T::Array[Integer]).returns(T::Array[Integer]) }
    def self.expand_range(episodes)
      return episodes unless episodes.size == 2

      first, last = episodes
      return episodes if first.nil? || last.nil? || last <= first || last - first > 10

      (first..last).to_a
    end
    private_class_method :expand_range

    sig { params(folder: String).returns(T.nilable(Integer)) }
    def self.season_from_folder(folder)
      return 0 if folder.match?(/\A(specials?|season[\s._-]*0+)\z/i)

      folder[SEASON_FOLDER, 1]&.to_i
    end
    private_class_method :season_from_folder

    sig { params(stem: String, folders: T::Array[String]).returns(T.nilable(String)) }
    def self.extra_kind(stem, folders)
      suffix = stem[EXTRA_SUFFIX, 1]
      return suffix.downcase.sub("behindthescenes", "behind_the_scenes").sub("deleted", "deleted_scene") if suffix

      # Only the file's own folder, and only inside a title's folder:
      # "Heat (1995)/Featurettes/x.mkv" is an extra, a top-level "Other/"
      # full of films is not.
      return nil if folders.size < 2

      EXTRA_FOLDERS[folders.last.to_s.downcase]
    end
    private_class_method :extra_kind

    # A show's title and year from its folder's name alone ("Bluey (2018)").
    sig { params(folder: String).returns([ String, T.nilable(Integer) ]) }
    def self.show_title(folder)
      title, year = title_and_year(strip_ids(folder))
      [ title.presence || folder, year ]
    end

    sig { params(path: String).returns(Ids) }
    def self.id_hints(path)
      Ids.new(
        tmdb_id: path[/[\[{]tmdb(?:id)?[-=](\d+)[\]}]/i, 1]&.to_i,
        imdb_id: path[/[\[{]imdb(?:id)?[-=](tt\d{7,9})[\]}]/i, 1] || path[/\b(tt\d{7,9})\b/, 1],
        tvdb_id: path[/[\[{]tvdb(?:id)?[-=](\d+)[\]}]/i, 1]&.to_i
      )
    end
    private_class_method :id_hints

    sig { params(name: String).returns(String) }
    def self.strip_ids(name)
      name.gsub(/[\[{](?:tmdb|imdb|tvdb)(?:id)?[-=][^\]}]*[\]}]/i, " ").gsub(/\{edition-[^}]*\}/i, " ")
    end
    private_class_method :strip_ids

    sig { params(name: String).returns(T.nilable(String)) }
    def self.edition(name)
      plex = name[/\{edition-([^}]+)\}/i, 1]
      return plex.strip if plex

      EDITIONS.each { |pattern, label| return label if name.match?(pattern) }
      nil
    end
    private_class_method :edition

    # Title is everything before the year (the last plausible one, so
    # "2001 A Space Odyssey 1968" keeps its leading 2001), cut at the first
    # noise word when there's no year.
    sig { params(name: String).returns([ String, T.nilable(Integer) ]) }
    def self.title_and_year(name)
      spaced = separators_to_spaces(name)
      matches = spaced.to_enum(:scan, YEAR).map { T.must(Regexp.last_match) }
      year_match = matches.reverse.find { |match| match.begin(1).positive? }
      if year_match
        year = year_match[1].to_i
        return [ clean_title(spaced[0, year_match.begin(1)].to_s), year ] if year <= Date.current.year + 2
      end

      words = spaced.split
      cut = words.index { |word| NOISE.include?(word.downcase.delete("[]()")) } || words.size
      [ clean_title(words.first(cut).join(" ")), nil ]
    end
    private_class_method :title_and_year

    # Scene names use dots or underscores for spaces; a name that already has
    # spaces keeps its dots ("Mr. Robot", "S.W.A.T.").
    sig { params(name: String).returns(String) }
    def self.separators_to_spaces(name)
      name.include?(" ") ? name.tr("_", " ") : name.tr("._", "  ")
    end
    private_class_method :separators_to_spaces

    sig { params(name: String).returns(String) }
    def self.clean_title(name)
      separators_to_spaces(name).gsub(/[\[(]\s*[\])]/, " ").gsub(/[\s\-_(\[]+\z/, "").gsub(/\A[\s\-_]+/, "")
        .squeeze(" ").strip
    end
    private_class_method :clean_title

    # For comparing titles across sources: case, accents, punctuation, "&"
    # and a leading article all stop mattering.
    sig { params(title: String).returns(String) }
    def self.normalize(title)
      I18n.transliterate(title).downcase.gsub("&", " and ").gsub(/[^a-z0-9 ]/, " ").squeeze(" ").strip
        .delete_prefix("the ").delete_prefix("a ")
    end
  end
end
