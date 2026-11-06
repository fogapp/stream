# typed: strict
# frozen_string_literal: true

module Youtube
  # One trailer, with yt-dlp, into storage (PROPOSAL §7.1–7.2): H.264 and
  # AAC in MP4 up to 1080p, which every browser plays as it is.
  class TrailerFetch
    extend T::Sig

    FORMAT = "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/b[vcodec^=avc1][height<=1080]/bv*[height<=1080]+ba/b"

    sig { params(trailer: Trailer).void }
    def initialize(trailer)
      @trailer = trailer
    end

    sig { void }
    def call
      FileUtils.mkdir_p(Trailer.root)
      @trailer.update!(attempts: @trailer.attempts + 1)
      temp = Dir.mktmpdir("stream-trailer")
      begin
        result = YtDlp.download(Urls.video_url(@trailer.youtube_id), args(temp))
        written = YtDlp.written_path(result, within: temp)
        raise YtDlp::Error, "yt-dlp didn't write a file" if written.nil? || !File.file?(written)

        FileUtils.mv(written, @trailer.path)
        @trailer.update!(state: Trailer::State::Ready.serialize, size: @trailer.path.size, error: nil)
      rescue YtDlp::Error, ToolRunner::Error => e
        # Recorded on the trailer, not retried here: FetchTrailersJob tries
        # again tomorrow, up to MAX_ATTEMPTS.
        @trailer.update!(state: Trailer::State::Failed.serialize, error: e.message.truncate(500))
      ensure
        FileUtils.rm_rf(temp)
      end
    end

    private

    sig { params(temp: String).returns(T::Array[String]) }
    def args(temp)
      [
        "--no-simulate", "--print", "after_move:filepath", "--quiet", "--no-playlist",
        "-f", FORMAT, "--merge-output-format", "mp4", "--paths", "home:#{temp}", "--output", "trailer.%(ext)s",
        "--retries", "3", "--socket-timeout", "30", "--no-part"
      ]
    end
  end
end
