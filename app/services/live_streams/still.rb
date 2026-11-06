# typed: strict
# frozen_string_literal: true

module LiveStreams
  # A live stream's picture a few minutes ago at most (PROPOSAL §7.8), for
  # its card. Taken from its relay when one is running — no new connection
  # to the camera — and otherwise from the source itself, which doubles as
  # the check that it's still there. Kept in the cache, since it can always
  # be taken again (CLAUDE.md invariant 1).
  module Still
    extend T::Sig

    WIDTH = 640
    # Long enough for a camera's next keyframe, and a web stream's playlist
    # and first segment.
    TIMEOUT = 30

    sig { returns(Pathname) }
    def self.root = Playback::Cache.root.parent.join("stills")

    sig { params(stream_id: String).returns(Pathname) }
    def self.path(stream_id) = root.join("#{stream_id}.webp")

    # Takes one, and says whether it came from a relay (nothing learned
    # about the source) or from the source (which answered). A source that
    # doesn't raises Prober::Failure, in words without its address.
    sig { params(stream: LiveStream).returns(Symbol) }
    def self.capture!(stream)
      FileUtils.mkdir_p(root)
      Dir.mktmpdir("live-still") do |scratch|
        relayed = from_relay(stream, Pathname.new(scratch))
        input = if relayed
          [ "-protocol_whitelist", "file", "-i", "file:#{relayed}" ]
        else
          live = Playback::FfmpegArgs::Input.live(stream)
          live.options + [ "-protocol_whitelist", live.protocols, "-i", live.url ]
        end
        out = Pathname.new(scratch).join("still.webp")
        argv = %w[ffmpeg -hide_banner -loglevel error -nostdin -y] + input +
          [ "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=#{WIDTH}:-2", "-c:v", "libwebp", "-quality", "75", out.to_s ]
        result = begin
          ToolRunner.run(argv, timeout: TIMEOUT)
        rescue ToolRunner::Timeout
          raise Prober::Failure, "#{stream.source} didn't send a picture within #{TIMEOUT} seconds"
        end
        raise Prober::Failure, Prober.explain(stream, result.stderr) unless result.success? && out.file? && out.size.positive?

        FileUtils.mv(out, path(stream.id))
        stream.update_columns(still_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        relayed ? :relay : :source
      end
    end

    # The newest segment of a relay of this stream that's running, with its
    # init segment in front: a whole fragmented MP4 ffmpeg can read.
    sig { params(stream: LiveStream, scratch: Pathname).returns(T.nilable(Pathname)) }
    def self.from_relay(stream, scratch)
      Playback::LiveCache.root.glob("#{stream.id}-*").each do |directory|
        playlist = directory.join(Playback::LiveCache::PLAYLIST)
        next unless playlist.file? && Time.current - playlist.mtime < 30

        name = playlist.read.scan(/^seg-\d+\.m4s$/).last
        init = directory.join("init.mp4")
        next unless name.is_a?(String) && init.file? && directory.join(name).file?

        # Copied file to file by the kernel, never read into Ruby strings: a
        # segment of a game is megabytes, every few minutes, for each stream.
        joined = scratch.join("relay.mp4")
        File.open(joined, "wb") do |out|
          IO.copy_stream(init.to_s, out)
          IO.copy_stream(directory.join(name).to_s, out)
        end
        return joined
      rescue SystemCallError
        next
      end
      nil
    end
    private_class_method :from_relay
  end
end
