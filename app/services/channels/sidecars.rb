# typed: strict
# frozen_string_literal: true

module Channels
  # What the files beside a video say about it (PROPOSAL §5.4), in order of
  # trust: yt-dlp's .info.json, then a Kodi-style .nfo, then the tags yt-dlp
  # embeds in the file, then only the folder and the file name.
  module Sidecars
    extend T::Sig

    # An info.json is a few hundred KB; one far bigger isn't one we'll parse.
    MAX_BYTES = T.let(8 * 1024 * 1024, Integer)

    class Details < T::Struct
      const :source, Video::Source
      const :title, T.nilable(String), default: nil
      const :description, T.nilable(String), default: nil
      const :upload_date, T.nilable(Date), default: nil
      const :youtube_id, T.nilable(String), default: nil
      const :url, T.nilable(String), default: nil
      const :tags, T::Array[String], default: []
      const :chapters, T::Array[T::Hash[String, T.untyped]], default: []
      const :channel_title, T.nilable(String), default: nil
      const :channel_youtube_id, T.nilable(String), default: nil
      const :channel_handle, T.nilable(String), default: nil
      const :channel_url, T.nilable(String), default: nil
    end

    sig { params(video_path: String, probe: T::Hash[String, T.untyped]).returns(Details) }
    def self.read(video_path, probe)
      base = video_path.delete_suffix(File.extname(video_path))
      from_info_json("#{base}.info.json") || from_nfo("#{base}.nfo") || from_tags(probe) ||
        Details.new(source: Video::Source::Folder)
    end

    # A channel-level info.json (yt-dlp --write-playlist-metafiles names it
    # after the channel, with its UC… id) in the channel's folder.
    sig { params(folder: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.channel_info(folder)
      Dir.glob("*\\[UC*\\].info.json", base: folder).first(3).each do |name|
        data = json(File.join(folder, name))
        return data if data && data["_type"] == "playlist" && data["channel_id"].present?
      end
      nil
    end

    # What yt-dlp says of a video — from an .info.json beside it, or asked of
    # YouTube once it was identified (Youtube::Hydrator).
    sig { params(data: T::Hash[String, T.untyped], source: Video::Source).returns(Details) }
    def self.from_info(data, source: Video::Source::InfoJson)
      Details.new(
        source: source, title: data["title"].presence || data["fulltitle"].presence,
        description: data["description"].presence, upload_date: date(data["upload_date"]),
        youtube_id: data["id"].to_s.match?(/\A[A-Za-z0-9_-]{11}\z/) ? data["id"] : nil,
        url: data["webpage_url"].presence, tags: Array(data["tags"]).map(&:to_s).first(50),
        chapters: Array(data["chapters"]).filter_map do |chapter|
          start = chapter["start_time"]
          { "start" => start.to_f, "end" => chapter["end_time"]&.to_f, "title" => chapter["title"].to_s } if start
        end,
        channel_title: data["channel"].presence || data["uploader"].presence, channel_youtube_id: data["channel_id"].presence,
        channel_handle: data["uploader_id"].to_s.start_with?("@") ? data["uploader_id"] : nil,
        channel_url: data["channel_url"].presence || data["uploader_url"].presence
      )
    end

    sig { params(path: String).returns(T.nilable(Details)) }
    def self.from_info_json(path)
      data = json(path)
      data && from_info(data)
    end

    sig { params(path: String).returns(T.nilable(Details)) }
    def self.from_nfo(path)
      return nil unless File.file?(path) && File.size(path) <= MAX_BYTES

      # No network, and entities left unexpanded: an NFO is untrusted XML.
      doc = Nokogiri::XML(File.read(path)) { |config| config.nonet }
      root = doc.root
      return nil if root.nil?

      text = ->(name) { root.at_xpath(name)&.text.presence }
      Details.new(
        source: Video::Source::Nfo, title: text.call("title"), description: text.call("plot"),
        upload_date: date(text.call("aired") || text.call("premiered") || text.call("releasedate")),
        youtube_id: root.at_xpath("uniqueid[@type='youtube']")&.text.presence,
        channel_title: text.call("studio") || text.call("showtitle"), tags: root.xpath("tag").map(&:text).first(50)
      )
    rescue Nokogiri::XML::SyntaxError, SystemCallError
      nil
    end

    # yt-dlp --embed-metadata: title, date, description (or comment), artist.
    sig { params(probe: T::Hash[String, T.untyped]).returns(T.nilable(Details)) }
    def self.from_tags(probe)
      tags = probe.dig("format", "tags")
      return nil unless tags.is_a?(Hash)

      tags = tags.transform_keys(&:downcase)
      return nil if tags["title"].blank? && tags["date"].blank?

      Details.new(
        source: Video::Source::Tags, title: tags["title"].presence, upload_date: date(tags["date"]),
        description: (tags["description"] || tags["comment"] || tags["synopsis"]).presence,
        channel_title: tags["artist"].presence, url: tags["purl"].presence
      )
    end

    sig { params(path: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.json(path)
      return nil unless File.file?(path) && File.size(path) <= MAX_BYTES

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # "20240131", "2024-01-31", "2024-01-31T10:00:00Z".
    sig { params(value: T.untyped).returns(T.nilable(Date)) }
    def self.date(value)
      text = value.to_s
      match = text.match(/\A(\d{4})-?(\d{2})-?(\d{2})/)
      return nil if match.nil?

      parts = [ match[1].to_i, match[2].to_i, match[3].to_i ]
      Date.valid_date?(*parts) ? Date.new(*parts) : nil
    end
    private_class_method :json, :from_info_json, :from_nfo, :from_tags
  end
end
