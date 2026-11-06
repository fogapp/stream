# typed: strict
# frozen_string_literal: true

module Youtube
  # Fetches one video into its channel's folder (PROPOSAL §5.4): the best
  # format that plays in a browser as it is (H.264 and AAC in MP4, up to
  # the channel's height), with the info.json, thumbnail and subtitles the
  # channel shape reads. Then a scan of that folder takes it from there.
  # Fetched again, it goes over the file it fetched before.
  class Downloader
    extend T::Sig

    OUTPUT = "%(upload_date>%Y%m%d)s - %(title).150B [%(id)s].%(ext)s"
    LIVE_FILTER = "live_status!=is_live & live_status!=is_upcoming & live_status!=was_live & live_status!=post_live"

    sig { params(download: YoutubeDownload).void }
    def initialize(download)
      @download = download
      @channel = T.let(download.channel || raise(ActiveRecord::RecordNotFound), Channel)
    end

    sig { void }
    def call
      library = @channel.library
      root = library&.download_root
      raise Tracker::NoDownloadFolder, "No download folder is set in Settings › YouTube" if library.nil? || root.nil?

      folder = File.join(root, @channel.folder)
      previous = @download.path
      FileUtils.mkdir_p(folder)
      # A fresh scratch folder each try: yt-dlp takes a format file a failed
      # try left there for one already downloaded, and merges the cut-off
      # video with whole audio.
      FileUtils.rm_rf(temp_dir)
      FileUtils.mkdir_p(temp_dir)
      @download.update!(state: YoutubeDownload::State::Downloading.serialize, started_at: Time.current, attempts: @download.attempts + 1)
      result = YtDlp.download(Urls.video_url(@download.youtube_id), args(folder))
      path = YtDlp.written_path(result, within: root)

      if path.nil?
        @download.update!(state: YoutubeDownload::State::Skipped.serialize, reason: skip_reason(result), finished_at: Time.current)
        return
      end

      @download.update!(state: YoutubeDownload::State::Done.serialize, path: path, bytes: File.size(path), finished_at: Time.current,
        last_error: nil, reason: nil)
      replaced(previous, path, root) if previous && previous != path
      ScanLibraryJob.perform_later(library.id, folder)
    ensure
      FileUtils.rm_rf(temp_dir)
    end

    sig { params(folder: String).returns(T::Array[String]) }
    def args(folder)
      height = @channel.max_height
      format = "bv*[vcodec^=avc1][height<=#{height}]+ba[acodec^=mp4a]/b[vcodec^=avc1][height<=#{height}]/" \
               "bv*[height<=#{height}]+ba/b[height<=#{height}]/b"
      # A video someone asked for is fetched whatever the channel's rules say.
      rules = !@download.by_hand
      filters = rules && @channel.skip_live ? [ "--match-filters", LIVE_FILTER ] : []
      since = rules && @channel.backfill_by_date? && @channel.backfill_since ? [ "--dateafter", T.must(@channel.backfill_since).strftime("%Y%m%d") ] : []
      # A row with a path was fetched before: this is fetching it again.
      overwrite = @download.path ? "--force-overwrites" : "--no-overwrites"
      [
        "--no-simulate", "--print", "after_move:filepath", "--quiet",
        "-f", format, "--merge-output-format", "mp4/mkv",
        "--paths", "home:#{folder}", "--paths", "temp:#{temp_dir}", "--output", OUTPUT, "--windows-filenames",
        "--write-info-json", "--no-write-playlist-metafiles", "--write-thumbnail", "--convert-thumbnails", "jpg",
        "--write-subs", "--sub-langs", "en.*,-live_chat", "--sub-format", "vtt/srt/best",
        "--embed-metadata", "--embed-chapters", "--no-embed-info-json",
        "--retries", "5", "--socket-timeout", "30", overwrite, "--no-part",
        *filters, *since
      ]
    end

    private

    # Fetched again under another name (a new title, or mkv where it was
    # mp4): the old copy goes, and its sidecars unless the new ones share
    # its name.
    sig { params(previous: String, path: String, root: String).void }
    def replaced(previous, path, root)
      return unless Media::SafePath.within?(previous, root)

      same_name = previous.delete_suffix(File.extname(previous)) == path.delete_suffix(File.extname(path))
      same_name ? FileUtils.rm_f(previous) : DownloadFiles.delete(previous)
    end

    sig { returns(String) }
    def temp_dir
      File.join(ENV.fetch("STREAM_CACHE_DIR") { Rails.root.join("tmp", "cache").to_s }, "yt-dlp", @download.id)
    end

    sig { params(result: ToolRunner::Result).returns(String) }
    def skip_reason(result)
      text = "#{result.stdout}\n#{result.stderr}"
      return "A livestream" if text.match?(/live_status/)
      return "Older than the channel's start date" if text.match?(/upload date is not in range|dateafter/i)

      "Didn't pass the channel's rules"
    end
  end
end
