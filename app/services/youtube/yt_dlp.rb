# typed: strict
# frozen_string_literal: true

module Youtube
  # yt-dlp, the tool that talks to YouTube (PROPOSAL §5.4). The image bakes
  # one in; a newer copy that Stream updates itself lives in storage and
  # wins, because YouTube breaks old yt-dlps every few weeks. Every call is
  # argv-only through ToolRunner, with our config and nobody else's.
  module YtDlp
    extend T::Sig

    class Error < StandardError; end

    # Listing a channel's tab or resolving a link.
    LIST_TIMEOUT = 120
    # One video, at up to 4K, over a slow line.
    DOWNLOAD_TIMEOUT = T.let(3 * 3600, Integer)
    RELEASE_BINARIES = T.let({ "x86_64-linux" => "yt-dlp_linux", "aarch64-linux" => "yt-dlp_linux_aarch64",
                               "arm64-darwin" => "yt-dlp_macos", "x86_64-darwin" => "yt-dlp_macos" }.freeze, T::Hash[String, String])

    sig { returns(Pathname) }
    def self.managed_path
      Pathname.new(ENV.fetch("STREAM_STORAGE_DIR") { Rails.root.join("storage").to_s }).join("tools", "yt-dlp")
    end

    sig { returns(String) }
    def self.path = managed_path.executable? ? managed_path.to_s : "yt-dlp"

    # nil when there's no yt-dlp to run.
    sig { returns(T.nilable(String)) }
    def self.version
      result = ToolRunner.run([ path, "--version" ], timeout: 30)
      result.success? ? result.stdout.strip.presence : nil
    rescue ToolRunner::Error, SystemCallError
      nil
    end

    # The version for Settings, without starting a Python each time it's
    # read: kept until the managed copy changes (an update writes a new
    # file), or an hour for one found on PATH.
    sig { returns(T.nilable(String)) }
    def self.cached_version
      changed = managed_path.executable? ? managed_path.mtime.to_i : nil
      Rails.cache.fetch([ "yt-dlp-version", path, changed ], expires_in: 1.hour, skip_nil: true) { version }
    end

    # yt-dlp's JSON for a URL (built by Urls, never pasted text).
    sig { params(url: String, args: T::Array[String]).returns(T::Hash[String, T.untyped]) }
    def self.json(url, args = [])
      result = run([ "--dump-single-json", *args, "--", url ], timeout: LIST_TIMEOUT)
      data = JSON.parse(result.stdout)
      raise Error, "yt-dlp answered with something that isn't an object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise Error, "yt-dlp's answer wasn't JSON"
    end

    MISSING_TAB = /does not have a .* tab|not exist|404/i

    # One tab of a channel, listed. A channel with no Shorts or no streams
    # has no such tab, which is an empty one, not a failure.
    sig { params(youtube_id: String, tab: String, args: T::Array[String]).returns(T::Hash[String, T.untyped]) }
    def self.tab_listing(youtube_id, tab, args = [])
      json(Urls.tab_url(youtube_id, tab), [ "--flat-playlist", *args ])
    rescue Error => e
      raise unless tab != "videos" && e.message.match?(MISSING_TAB)

      {}
    end

    # The file a download's `--print after_move:filepath` named: the last
    # line. nil when it wrote nothing; an error when it wrote outside `within`.
    sig { params(result: ToolRunner::Result, within: String).returns(T.nilable(String)) }
    def self.written_path(result, within:)
      path = result.stdout.lines.map(&:strip).reject(&:empty?).last
      return nil if path.nil?
      raise Error, "yt-dlp wrote outside its folder" unless Media::SafePath.within?(path, within)

      path
    end

    # The fields of one video Stream reads (Resolver, Hydrator, Sidecars).
    # Its whole JSON runs to megabytes — formats, and automatic captions
    # translated into every language (11 MB for one Brewers highlight) —
    # past what ToolRunner keeps, so the cut answer wasn't JSON.
    VIDEO_FIELDS = %w[id title fulltitle description upload_date webpage_url tags chapters channel channel_id channel_url
                      channel_handle uploader uploader_id uploader_url thumbnail thumbnails].freeze

    # One video's JSON, those fields only.
    sig { params(url: String).returns(T::Hash[String, T.untyped]) }
    def self.video(url)
      result = run([ "--no-playlist", "--print", "%(.{#{VIDEO_FIELDS.join(',')}})j", "--", url ], timeout: LIST_TIMEOUT)
      data = JSON.parse(result.stdout)
      raise Error, "yt-dlp answered with something that isn't an object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise Error, "yt-dlp's answer wasn't JSON"
    end

    sig { params(url: String, args: T::Array[String]).returns(ToolRunner::Result) }
    def self.download(url, args) = run([ *args, "--", url ], timeout: DOWNLOAD_TIMEOUT)

    # A live stream's HLS playlists (PROPOSAL §7.8), the best picture's and
    # the best sound's — YouTube serves them apart — or one that carries
    # both. None when the video isn't live: it passes the filter only while
    # it is.
    LIVE_FORMAT = "bv*[protocol^=m3u8]+ba[protocol^=m3u8]/b[protocol^=m3u8]"
    # A probe waits on this, so it's far shorter than a listing's.
    RESOLVE_TIMEOUT = 45

    sig { params(url: String).returns(T::Array[String]) }
    def self.live_urls(url)
      result = run([ "--match-filter", "is_live", "--format", LIVE_FORMAT, "--get-url", "--", url ], timeout: RESOLVE_TIMEOUT)
      result.stdout.lines.map(&:strip).select { |line| line.start_with?("https://") }
    end

    class Info < T::Struct
      const :data, T::Hash[String, T.untyped]
      # What yt-dlp warned of: MLB.tv's reason a broadcast has no formats
      # (a blackout, no subscription) is only ever a warning.
      const :warnings, T::Array[String]
    end

    # A page's JSON with its formats, even none, and the warnings with it —
    # for a source that picks its own format (LiveStreams::MlbSource). args
    # carries the sign-in (--netrc-location), never a password.
    sig { params(url: String, args: T::Array[String]).returns(Info) }
    def self.info(url, args = [])
      result = run([ "--dump-single-json", "--ignore-no-formats-error", *args, "--", url ], timeout: RESOLVE_TIMEOUT, warnings: true)
      data = JSON.parse(result.stdout)
      raise Error, "yt-dlp answered with something that isn't an object" unless data.is_a?(Hash)

      Info.new(data: data, warnings: result.stderr.lines.grep(/\AWARNING: /).map { |line| line.strip.delete_prefix("WARNING: ") })
    rescue JSON::ParserError
      raise Error, "yt-dlp's answer wasn't JSON"
    end

    # Brings the managed copy up to date, fetching it the first time.
    # Returns the version now in use.
    sig { returns(T.nilable(String)) }
    def self.update!
      target = managed_path
      if target.executable?
        ToolRunner.run([ target.to_s, "--update" ], timeout: 300)
      else
        binary = RELEASE_BINARIES["#{RbConfig::CONFIG['host_cpu'].sub('amd64', 'x86_64')}-#{RbConfig::CONFIG['host_os'][/linux|darwin/]}"]
        raise Error, "No yt-dlp build for this machine" if binary.nil?

        FileUtils.mkdir_p(target.dirname)
        Releases.new.fetch(binary, into: target)
        target.chmod(0o755)
      end
      version
    end

    sig { params(argv: T::Array[String], timeout: Integer, warnings: T::Boolean).returns(ToolRunner::Result) }
    def self.run(argv, timeout:, warnings: false)
      result = ToolRunner.run([ path, "--ignore-config", *(warnings ? [] : [ "--no-warnings" ]), "--no-progress", *argv ], timeout: timeout)
      return result if result.success?

      message = result.stderr.lines.grep(/ERROR/).last || result.stderr.lines.last || "exited #{result.status}"
      raise Error, message.strip.delete_prefix("ERROR: ").truncate(300)
    rescue ToolRunner::Timeout => e
      raise Error, e.message
    rescue SystemCallError => e
      raise Error, "Couldn't run yt-dlp: #{e.message}"
    end
    private_class_method :run

    # yt-dlp's own release downloads, from GitHub.
    class Releases
      extend T::Sig
      include UpstreamHttpClient

      BASE = "https://github.com/yt-dlp/yt-dlp/releases/latest/download"

      sig { override.returns(String) }
      def service_name = "GitHub"

      sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
      def error_class = UpstreamHttpClient::Error

      sig { params(binary: String, into: Pathname).void }
      def fetch(binary, into:)
        partial = Pathname.new("#{into}.partial")
        http_get_file("#{BASE}/#{binary}", into: partial, max_bytes: 80 * 1024 * 1024, redirects_left: 5)
        partial.rename(into.to_s)
      end
    end
  end
end
