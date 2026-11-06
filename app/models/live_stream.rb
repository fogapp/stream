# typed: strict
# frozen_string_literal: true

# A camera or a web stream an admin added by URL (PROPOSAL §7.8), played like
# a title but never a file: Stream relays it, so the browser never opens the
# URL. The URL is a secret — a camera's credentials, or UniFi Protect's token
# in the path — so it's encrypted, never serialized, and shown everywhere as
# `source`: scheme, host and port. A YouTube or MLB.tv link is no secret,
# and is its own source. A team's MLB.tv stream (mlb_team_id) has no link
# and no library: it plays whatever game the team is on in (Baseball).
class LiveStream < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      # On the LAN, usually RTSP: seconds behind live matter.
      Camera = new("camera")
      # A single HLS or DASH stream from the web.
      Web = new("web")
      # A YouTube live stream, by its link or its channel's: yt-dlp finds
      # the playlists (LiveStreams::YoutubeSource).
      Youtube = new("youtube")
      # An MLB.tv game, by its link, or a team's games (mlb_team_id): yt-dlp
      # signs in with the household's account (MlbSetting) and
      # LiveStreams::MlbSource picks the broadcast.
      Mlb = new("mlb")
    end

    # What a player says under its name when it has no description.
    sig { returns(String) }
    def label
      case self
      when Camera then "Camera"
      when Web then "Web stream"
      when Youtube then "YouTube"
      when Mlb then "MLB.tv"
      else T.absurd(self)
      end
    end
  end

  class Status < T::Enum
    include ApplicationEnum
    enums do
      Online = new("online")
      # The last probe or relay couldn't reach it (last_error says why).
      Offline = new("offline")
    end
  end

  # Which of a game's TV broadcasts an MLB.tv stream plays.
  class Feed < T::Enum
    include ApplicationEnum
    enums do
      Home = new("home")
      Away = new("away")
    end
  end

  SCHEMES = T.let(%w[rtsp rtsps http https].freeze, T::Array[String])
  TOKEN_LENGTH = 8
  # The playlist addresses a YouTube link resolves to carry a signature and
  # the server's own address.
  GOOGLEVIDEO = %r{https?://[^\s"']*googlevideo\.com[^\s"']*}
  # An MLB.tv game's playlists carry a token; nothing but the game's own
  # link is worth keeping from a tool's words.
  ANY_URL = %r{https?://[^\s"']+(?<![.,;:)])}
  # What a team's stream keeps as its link: the game it plays is found when
  # it starts (LiveStreams::MlbSource).
  TEAM_URL = "https://www.mlb.com/tv"

  belongs_to :library, optional: true
  # The streams an admin added: what Settings, the live library and the
  # five-minute pictures cover. A team's is Baseball's (Mlb::TeamStreams).
  scope :added, -> { where(mlb_team_id: nil) }
  has_many :media_streams, -> { order(:index) }, dependent: :delete_all, inverse_of: :live_stream
  has_many :analysis_runs, dependent: :delete_all

  # Its card picture goes with it (it lives in the cache, not the database).
  after_destroy_commit { FileUtils.rm_f(LiveStreams::Still.path(T.bind(self, LiveStream).id)) }

  attribute :kind, Kind
  attribute :status, Status
  attribute :feed, Feed, allow_nil: true

  encrypts :url

  normalizes :name, with: ->(name) { name.strip }
  normalizes :url, with: ->(url) { url.strip }

  validates :name, presence: true, length: { maximum: 100 }
  validates :description, length: { maximum: 2000 }
  validate :url_is_a_stream
  validate :library_is_live
  validates :feed, presence: true, if: :game?
  validates :library, presence: true, unless: :team?
  validates :mlb_team_id, uniqueness: { scope: :household_id }, allow_nil: true
  validate :team_is_mlb, if: :team?

  before_validation { self.sort_title = name.to_s.downcase }
  before_validation :canonical_youtube_url, if: :youtube?
  before_validation :canonical_mlb_url, if: :game?
  before_validation { self.url = TEAM_URL if team? }
  before_validation { self.feed = nil unless game? }
  before_save { self.rating_age = ContentRatings.age(content_rating) }

  # scheme://host:port — what every screen, log and error says instead of
  # the URL.
  sig { returns(String) }
  def source = youtube? || mlb? ? url.to_s.sub(%r{\Ahttps://(www\.)?}, "") : self.class.source_of(url.to_s)

  sig { returns(T::Boolean) }
  def youtube? = kind_enum == Kind::Youtube

  sig { returns(T::Boolean) }
  def mlb? = kind_enum == Kind::Mlb

  # A team's MLB.tv stream, rather than one an admin added.
  sig { returns(T::Boolean) }
  def team? = !mlb_team_id.nil?

  # An MLB.tv game an admin added by its link.
  sig { returns(T::Boolean) }
  def game? = mlb? && !team?


  sig { params(url: String).returns(String) }
  def self.source_of(url)
    uri = URI.parse(url)
    host = uri.host.to_s
    host = "[#{host}]" if host.include?(":") && !host.start_with?("[")
    port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
    "#{uri.scheme}://#{host}#{port}"
  rescue URI::InvalidURIError
    "a stream address"
  end

  # Text from a tool that was handed the URL, with every trace of it
  # replaced by the source: the URL whole, its path, its query, its
  # credentials.
  sig { params(text: String).returns(String) }
  def redact(text)
    text = text.gsub(GOOGLEVIDEO, "YouTube's stream")
    return text.gsub(ANY_URL) { |found| found == url.to_s ? found : "MLB.tv's stream" } if mlb?

    youtube? ? text : self.class.redact(text, url.to_s)
  end

  sig { params(text: String, url: String).returns(String) }
  def self.redact(text, url)
    return text if url.empty?

    secrets = [ url ]
    begin
      uri = URI.parse(url)
      secrets << uri.userinfo.to_s << uri.password.to_s << uri.path.to_s << uri.path.to_s.delete_prefix("/") << uri.query.to_s
      # A token is one segment of the path; short words ("live", "hls")
      # aren't, and replacing them would garble the message.
      secrets += uri.path.to_s.split("/").select { |segment| segment.length >= TOKEN_LENGTH }
    rescue URI::InvalidURIError
      nil
    end
    secrets.map(&:to_s).select { |secret| secret.length >= 4 && secret != "/" }.uniq.sort_by { |secret| -secret.length }
      .reduce(text) { |redacted, secret| redacted.gsub(secret, secret == url ? source_of(url) : "…") }
  end

  sig { returns(T::Boolean) }
  def online? = status_enum == Status::Online

  # What a title is called everywhere a title is shown.
  sig { returns(String) }
  def title = name

  sig { returns(T.nilable(MediaStream)) }
  def primary_video = media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Video }

  private

  sig { void }
  def url_is_a_stream
    return youtube_url_is_live if youtube?
    return if team?
    return mlb_url_is_a_game if mlb?

    uri = URI.parse(url.to_s)
    if !SCHEMES.include?(uri.scheme.to_s.downcase) || uri.host.blank?
      errors.add(:url, "must be an rtsp://, rtsps://, http:// or https:// address")
    elsif Youtube::Urls::HOSTS.include?(uri.host.to_s.downcase)
      errors.add(:url, "is a YouTube link: choose YouTube as its kind")
    elsif Mlb::Urls::HOSTS.include?(uri.host.to_s.downcase)
      errors.add(:url, "is an MLB.tv link: choose MLB.tv as its kind")
    end
  rescue URI::InvalidURIError
    errors.add(:url, "isn't an address")
  end

  sig { void }
  def youtube_url_is_live
    Youtube::Urls.live_url(url.to_s)
  rescue Youtube::Urls::Invalid => e
    errors.add(:base, e.message)
  end

  # Kept as the URL Youtube::Urls builds from the id, so a pasted link's
  # tracking parameters and the like never reach yt-dlp.
  sig { void }
  def canonical_youtube_url
    self.url = Youtube::Urls.live_url(url.to_s)
  rescue Youtube::Urls::Invalid
    nil
  end

  sig { void }
  def mlb_url_is_a_game
    Mlb::Urls.game_url(url.to_s)
  rescue Mlb::Urls::Invalid => e
    errors.add(:base, e.message)
  end

  # Kept as the game's link alone, rebuilt from its number.
  sig { void }
  def canonical_mlb_url
    self.url = Mlb::Urls.game_url(url.to_s)
  rescue Mlb::Urls::Invalid
    nil
  end

  sig { void }
  def team_is_mlb
    errors.add(:kind, "must be MLB.tv for a team's stream") unless mlb?
  end

  sig { void }
  def library_is_live
    return if library.nil? || library&.kind == Library::Kind::Live.serialize

    errors.add(:library, "must be a live library")
  end
end
