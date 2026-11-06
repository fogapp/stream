# typed: strict
# frozen_string_literal: true

module Subtitles
  # Every subtitle a file has (PROPOSAL §5.5, §6.2): its own embedded
  # tracks, and sidecar files beside it named the way Plex and Jellyfin
  # expect — "Heat (1995).en.srt", "Heat (1995).en.forced.srt".
  # Subtitles never force a transcode unless someone chooses one nothing
  # can draw (DVD and DVB bitmaps), which is then burned in.
  module Tracks
    extend T::Sig

    class Format < T::Enum
      include ApplicationEnum
      enums do
        # Plain text, shown by the browser's own <track> rendering.
        Vtt = new("vtt")
        # Styled text, drawn by JASSUB (libass) with the file's own fonts.
        Ass = new("ass")
        # Blu-ray bitmaps, drawn by libpgs.
        Pgs = new("pgs")
        # DVD (VobSub) and DVB bitmaps: nothing in a browser draws them, so
        # choosing one converts the video with it drawn in (Decision).
        Burn = new("burn")
      end
    end

    class Track < T::Struct
      const :id, String
      const :format, Format
      const :language, T.nilable(String)
      const :title, T.nilable(String)
      const :forced, T::Boolean
      const :default, T::Boolean
      const :hearing_impaired, T::Boolean
      # Embedded: the stream index. Sidecar: the file's path.
      const :stream_index, T.nilable(Integer)
      const :sidecar_path, T.nilable(String)
      const :codec, String
      # Made by Stream from a Whisper transcript: "English (auto-generated)".
      const :generated, T::Boolean, default: false
    end

    TEXT_CODECS = T.let(%w[subrip ass ssa mov_text webvtt text].to_set.freeze, T::Set[String])
    SIDECAR_EXTENSIONS = T.let({ ".srt" => "subrip", ".vtt" => "webvtt", ".ass" => "ass", ".ssa" => "ssa", ".sup" => "hdmv_pgs_subtitle" }.freeze,
      T::Hash[String, String])
    HEARING_IMPAIRED = T.let(%w[sdh cc hi].to_set.freeze, T::Set[String])

    sig { params(file: MediaFile).returns(T::Array[Track]) }
    def self.for(file)
      embedded(file) + sidecars(file) + downloaded(file) + generated(file)
    end

    # Fetched from OpenSubtitles into storage (PROPOSAL §5.5), named
    # "<language>.<opensubtitles file id>.srt"; read like a sidecar.
    sig { params(file: MediaFile).returns(T::Array[Track]) }
    def self.downloaded(file)
      directory = Extractor.downloads_dir(file)
      return [] unless directory.directory?

      directory.children.select { |path| path.extname == ".srt" }.sort.map do |path|
        language = path.basename.to_s.split(".").first
        Track.new(id: "d#{Digest::SHA256.hexdigest(path.to_s).first(10)}", format: Format::Vtt, language: language,
          title: "OpenSubtitles", forced: false, default: false, hearing_impaired: false, stream_index: nil,
          sidecar_path: path.to_s, codec: "subrip")
      end
    end

    # A Whisper transcript, offered as captions (PROPOSAL §5.5).
    sig { params(file: MediaFile).returns(T::Array[Track]) }
    def self.generated(file)
      transcript = Transcript.find_by(media_file_id: file.id, source: Transcript::Source::Whisper.serialize)
      return [] if transcript.nil? || transcript.line_count.zero?

      [ Track.new(id: "g#{transcript.updated_at.to_i}", format: Format::Vtt, language: transcript.language, title: "Auto-generated",
          forced: false, default: false, hearing_impaired: false, stream_index: nil, sidecar_path: nil, codec: "webvtt", generated: true) ]
    end

    sig { params(file: MediaFile, id: String).returns(T.nilable(Track)) }
    def self.find(file, id) = self.for(file).find { |track| track.id == id }

    sig { params(file: MediaFile).returns(T::Array[Track]) }
    def self.embedded(file)
      file.media_streams.select { |stream| stream.kind_enum == MediaStream::Kind::Subtitle }.filter_map do |stream|
        format = format_for(stream.codec.to_s)
        next nil if format.nil?

        title = stream.title
        Track.new(id: "e#{stream.index}", format: format, language: stream.language, title: title, forced: stream.forced,
          default: stream.default, hearing_impaired: title.to_s.match?(/\b(sdh|cc|hearing)\b/i), stream_index: stream.index,
          sidecar_path: nil, codec: stream.codec.to_s)
      end
    end

    # What sits beside the video with the same name, as the scanner last saw
    # it (docs/PERF_PROPOSAL.md › P3): pressing Play never lists a folder on
    # the NAS. A file no scan has looked at since is listed once, and kept.
    sig { params(file: MediaFile).returns(T::Array[Track]) }
    def self.sidecars(file)
      names = file.sidecar_subtitles
      names = remember_sidecars(file) unless names.is_a?(Array)
      directory = File.dirname(file.path)
      stem = File.basename(file.path, ".*")
      names.map(&:to_s).sort.filter_map do |name|
        codec = SIDECAR_EXTENSIONS[File.extname(name).downcase]
        next nil if codec.nil?

        tags = File.basename(name, ".*").delete_prefix(stem).split(".").map(&:downcase).compact_blank
        path = File.join(directory, name)
        Track.new(id: "s#{Digest::SHA256.hexdigest(path).first(10)}", format: T.must(format_for(codec)),
          language: tags.find { |tag| tag.match?(/\A[a-z]{2,3}(-[a-z]{2})?\z/) && !HEARING_IMPAIRED.include?(tag) && tag != "forced" },
          title: nil, forced: tags.include?("forced"), default: tags.include?("default"),
          hearing_impaired: tags.any? { |tag| HEARING_IMPAIRED.include?(tag) }, stream_index: nil, sidecar_path: path, codec: codec)
      end
    end

    # Of the names in a video's folder, its subtitles: "Heat (1995).srt",
    # "Heat (1995).en.forced.srt".
    sig { params(video_path: String, names: T::Array[String]).returns(T::Array[String]) }
    def self.sidecar_names(video_path, names)
      stem = File.basename(video_path, ".*")
      names.select do |name|
        base = File.basename(name, ".*")
        SIDECAR_EXTENSIONS.key?(File.extname(name).downcase) && (base == stem || base.start_with?("#{stem}."))
      end.sort
    end

    # One listing of the folder, stored for next time.
    sig { params(file: MediaFile).returns(T::Array[String]) }
    def self.remember_sidecars(file)
      names = sidecar_names(file.path, Dir.children(File.dirname(file.path)))
      file.update_columns(sidecar_subtitles: names) if file.persisted? # rubocop:disable Rails/SkipsModelValidations
      names
    rescue SystemCallError
      []
    end

    # VobSub and DVB bitmaps have no browser renderer: offered to be burned
    # in, and only embedded (a sidecar .sub/.idx pair isn't read).
    sig { params(codec: String).returns(T.nilable(Format)) }
    def self.format_for(codec)
      return Format::Ass if %w[ass ssa].include?(codec)
      return Format::Vtt if TEXT_CODECS.include?(codec)
      return Format::Pgs if codec == "hdmv_pgs_subtitle"
      return Format::Burn if BURN_CODECS.include?(codec)

      nil
    end

    BURN_CODECS = T.let(%w[dvd_subtitle dvb_subtitle].to_set.freeze, T::Set[String])

    # Picture subtitles a device can't draw, burned in on request: DVD and
    # DVB everywhere, and PGS for a client without a renderer (Apple TV).
    sig { params(file: MediaFile, index: Integer).returns(T::Boolean) }
    def self.burnable?(file, index)
      file.media_streams.any? do |stream|
        stream.index == index && stream.kind_enum == MediaStream::Kind::Subtitle &&
          (BURN_CODECS.include?(stream.codec.to_s) || stream.codec == "hdmv_pgs_subtitle")
      end
    end
  end
end
