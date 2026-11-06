# typed: strict
# frozen_string_literal: true

module Youtube
  # What a pasted link is, asked of YouTube (PROPOSAL §5.4): the channel
  # behind it, with its name, handle and pictures — what Add channel shows
  # before anything is tracked.
  module Resolver
    extend T::Sig

    class ChannelInfo < T::Struct
      const :youtube_id, String
      const :title, String
      const :handle, T.nilable(String)
      const :description, T.nilable(String)
      const :avatar_url, T.nilable(String)
      const :banner_url, T.nilable(String)
    end

    class Preview < T::Struct
      const :kind, Urls::Kind
      const :url, String
      const :channel, T.nilable(ChannelInfo)
      # A single video, or a playlist's videos: [{ id, title, channel_id }].
      const :videos, T::Array[T::Hash[String, T.untyped]], default: []
      const :title, T.nilable(String), default: nil
    end

    sig { params(parsed: Urls::Parsed).returns(Preview) }
    def self.resolve(parsed)
      kind = parsed.kind
      case kind
      when Urls::Kind::Channel
        base = parsed.id.match?(Urls::CHANNEL_ID) ? Urls.channel_url(parsed.id) : parsed.url
        data = YtDlp.json("#{base}/videos", [ "--flat-playlist", "--playlist-end", "1" ])
        Preview.new(kind: parsed.kind, url: parsed.url, channel: channel_info(data), title: data["channel"].presence)
      when Urls::Kind::Video
        data = YtDlp.video(parsed.url)
        Preview.new(kind: parsed.kind, url: parsed.url, channel: channel_info(data), title: data["title"].presence,
          videos: [ { "id" => data["id"], "title" => data["title"], "channel_id" => data["channel_id"] } ])
      when Urls::Kind::Playlist
        data = YtDlp.json(parsed.url, [ "--flat-playlist" ])
        entries = Array(data["entries"]).filter_map do |entry|
          id = entry["id"].to_s
          { "id" => id, "title" => entry["title"], "channel_id" => entry["channel_id"] || data["channel_id"] } if id.match?(Urls::VIDEO_ID)
        end
        Preview.new(kind: parsed.kind, url: parsed.url, channel: data["channel_id"].present? ? channel_info(data) : nil,
          title: data["title"].presence, videos: entries)
      else T.absurd(kind)
      end
    end

    sig { params(data: T::Hash[String, T.untyped]).returns(T.nilable(ChannelInfo)) }
    def self.channel_info(data)
      id = data["channel_id"].to_s
      return nil unless id.match?(Urls::CHANNEL_ID)

      thumbs = Array(data["thumbnails"]).to_h { |thumb| [ thumb["id"].to_s, thumb["url"].to_s ] }
      handle = [ data["uploader_id"], data["channel_handle"] ].map(&:to_s).find { |value| value.start_with?("@") }
      ChannelInfo.new(
        youtube_id: id, title: (data["channel"].presence || data["uploader"].presence || id).to_s, handle: handle,
        description: data["description"].presence && data["_type"] == "playlist" ? data["description"] : nil,
        avatar_url: thumbs["avatar_uncropped"].presence, banner_url: thumbs["banner_uncropped"].presence
      )
    end
  end
end
