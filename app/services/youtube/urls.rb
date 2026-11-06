# typed: strict
# frozen_string_literal: true

module Youtube
  # What a pasted link is, rebuilt as a canonical YouTube URL (PROPOSAL
  # §5.4). yt-dlp can fetch from thousands of sites, some of them on the
  # LAN; only a URL this module built from a validated id is ever handed
  # to it, so a pasted link can't point it anywhere else.
  module Urls
    extend T::Sig

    class Invalid < StandardError; end

    class Kind < T::Enum
      include ApplicationEnum
      enums do
        Channel = new("channel")
        Video = new("video")
        Playlist = new("playlist")
      end
    end

    class Parsed < T::Struct
      const :kind, Kind
      const :id, String
      const :url, String
    end

    HOSTS = T.let(%w[youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be www.youtu.be].to_set.freeze, T::Set[String])
    VIDEO_ID = /\A[A-Za-z0-9_-]{11}\z/
    CHANNEL_ID = /\AUC[A-Za-z0-9_-]{22}\z/
    PLAYLIST_ID = /\A[A-Za-z0-9_-]{10,64}\z/
    HANDLE = /\A@[\w.\-·]{3,30}\z/
    LEGACY_NAME = /\A[\w.\-]{1,100}\z/

    sig { params(text: String).returns(Parsed) }
    def self.parse(text)
      raw = text.strip
      raw = "https://#{raw}" unless raw.match?(%r{\Ahttps?://}i)
      uri = URI.parse(raw)
      host = uri.host.to_s.downcase
      raise Invalid, "That isn't a YouTube link" unless HOSTS.include?(host)

      query = URI.decode_www_form(uri.query.to_s).to_h
      segments = uri.path.to_s.split("/").reject(&:empty?)
      return video(segments.first.to_s) if host.end_with?("youtu.be")

      first = segments.first.to_s
      case first
      when "watch" then query["v"] ? video(query["v"].to_s) : playlist(query["list"].to_s)
      when "shorts", "live", "embed", "v" then video(segments[1].to_s)
      when "playlist" then playlist(query["list"].to_s)
      when "channel"
        id = segments[1].to_s
        raise Invalid, "That channel link has no channel id" unless id.match?(CHANNEL_ID)

        Parsed.new(kind: Kind::Channel, id: id, url: channel_url(id))
      when "c", "user"
        name = segments[1].to_s
        raise Invalid, "That channel link has no name" unless name.match?(LEGACY_NAME)

        Parsed.new(kind: Kind::Channel, id: name, url: "https://www.youtube.com/#{first}/#{name}")
      else
        handle = URI.decode_www_form_component(first)
        raise Invalid, "Paste a channel, video or playlist link" unless handle.match?(HANDLE)

        Parsed.new(kind: Kind::Channel, id: handle, url: "https://www.youtube.com/#{handle}")
      end
    rescue URI::InvalidURIError, ArgumentError
      raise Invalid, "That isn't a link"
    end

    sig { params(channel_id: String).returns(String) }
    def self.channel_url(channel_id)
      raise Invalid, "Not a channel id" unless channel_id.match?(CHANNEL_ID)

      "https://www.youtube.com/channel/#{channel_id}"
    end

    # A channel's tab: videos, shorts or streams.
    sig { params(channel_id: String, tab: String).returns(String) }
    def self.tab_url(channel_id, tab)
      raise Invalid, "Not a tab" unless %w[videos shorts streams].include?(tab)

      "#{channel_url(channel_id)}/#{tab}"
    end

    sig { params(id: String).returns(String) }
    def self.video_url(id)
      raise Invalid, "That video link has no video id" unless id.match?(VIDEO_ID)

      "https://www.youtube.com/watch?v=#{id}"
    end

    # A live stream to relay (PROPOSAL §7.8): a video's link, or a channel's,
    # which plays whatever the channel has live — a stream that YouTube gives
    # a new id when it restarts is still found.
    sig { params(text: String).returns(String) }
    def self.live_url(text)
      parsed = parse(text)
      kind = parsed.kind
      case kind
      when Kind::Video then parsed.url
      when Kind::Channel then "#{parsed.url}/live"
      when Kind::Playlist then raise Invalid, "A playlist isn't a live stream: paste the stream's link, or its channel's"
      else T.absurd(kind)
      end
    end

    sig { params(id: String).returns(Parsed) }
    def self.video(id) =Parsed.new(kind: Kind::Video, id: id, url: video_url(id))

    sig { params(id: String).returns(Parsed) }
    def self.playlist(id)
      raise Invalid, "That playlist link has no playlist id" unless id.match?(PLAYLIST_ID)

      Parsed.new(kind: Kind::Playlist, id: id, url: "https://www.youtube.com/playlist?list=#{id}")
    end
    private_class_method :video, :playlist
  end
end
