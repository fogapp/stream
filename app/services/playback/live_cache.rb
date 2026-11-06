# typed: strict
# frozen_string_literal: true

module Playback
  # Where a live stream's relay (PROPOSAL §7.8) writes on the shared cache
  # volume, and how web and the transcoder talk through it: web touches
  # `wanted` on every playlist request, the transcoder keeps the relay
  # running while it's fresh and says how it's going in `status.json`.
  #
  # One relay per stream and per decision — what's copied and what's
  # converted — shared by everyone watching it that way: a camera answers a
  # handful of connections, and three viewers hold one.
  module LiveCache
    extend T::Sig

    PLAYLIST = "index.m3u8"

    sig { returns(Pathname) }
    def self.root = Cache.root.parent.join("live")

    # The stream's id and a digest of how it's relayed — of the decision
    # with its keys in order, since jsonb keeps them in its own: the same
    # decision read back from the session has to make the same key.
    sig { params(stream_id: String, decision: T::Hash[String, T.untyped]).returns(String) }
    def self.key(stream_id, decision)
      how = canonical({ "video" => decision["video"], "audio" => decision["audio"] }).to_json
      "#{stream_id}-#{Digest::SHA256.hexdigest(how).first(10)}"
    end

    sig { params(value: T.untyped).returns(T.untyped) }
    def self.canonical(value)
      case value
      when Hash then value.to_h { |key, inner| [ key.to_s, canonical(inner) ] }.compact.sort.to_h
      when Array then value.map { |inner| canonical(inner) }
      else value
      end
    end
    private_class_method :canonical

    sig { params(session: PlaybackSession).returns(String) }
    def self.key_for(session) = key(session.playable_id, session.decision)

    sig { params(key: String).returns(Pathname) }
    def self.directory(key) = root.join(key)

    sig { params(key: String).returns(Pathname) }
    def self.playlist(key) = directory(key).join(PLAYLIST)

    # Someone is watching (or about to): the relay keeps going while this is
    # fresh.
    sig { params(key: String).void }
    def self.want!(key)
      FileUtils.mkdir_p(directory(key))
      FileUtils.touch(directory(key).join("wanted"), mtime: Time.current.to_time)
    end

    sig { params(key: String).returns(T.nilable(Time)) }
    def self.wanted_at(key)
      File.mtime(directory(key).join("wanted"))
    rescue SystemCallError
      nil
    end

    # A playlist with at least one finished segment in it.
    sig { params(key: String).returns(T::Boolean) }
    def self.ready?(key)
      File.read(playlist(key)).include?("#EXTINF")
    rescue SystemCallError
      false
    end

    # Segments the playlist no longer names, gone: ffmpeg deletes those
    # that slide out of its own window, but a run killed mid-stream leaves
    # its last ones behind, and the next appends past them. Only files older
    # than `grace`, so one written a moment before the playlist names it
    # stays; and nothing at all when the playlist can't be read, since then
    # every segment would look unnamed.
    sig { params(key: String, grace: Float).returns(Integer) }
    def self.prune!(key, grace: 60.0)
      text = File.read(playlist(key))
      return 0 unless text.include?("#EXTINF")

      named = text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }.to_set
      cutoff = Time.current - grace
      directory(key).glob("seg-*.m4s").count do |path|
        next false if named.include?(path.basename.to_s) || path.mtime > cutoff

        path.delete
        true
      rescue SystemCallError
        false
      end
    rescue SystemCallError
      0
    end

    class Status < T::Struct
      # "starting", "live", "reconnecting"
      const :state, String
      const :message, T.nilable(String), default: nil
      const :at, Float
    end

    sig { params(key: String, state: String, message: T.nilable(String)).void }
    def self.write_status(key, state, message = nil)
      directory = directory(key)
      FileUtils.mkdir_p(directory)
      temp = directory.join("status.json.tmp")
      File.write(temp, { "state" => state, "message" => message, "at" => Time.current.to_f }.to_json)
      File.rename(temp, directory.join("status.json"))
    end

    sig { params(key: String).returns(T.nilable(Status)) }
    def self.status(key)
      raw = JSON.parse(File.read(directory(key).join("status.json")))
      Status.new(state: raw["state"].to_s, message: raw["message"], at: raw["at"].to_f)
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # A file the relay wrote, by the name its playlist gives it: init.mp4
    # or seg-<n>.m4s, nothing else.
    sig { params(key: String, name: String).returns(T.nilable(Pathname)) }
    def self.file(key, name)
      return nil unless name == "init.mp4" || name.match?(/\Aseg-\d+\.m4s\z/)

      path = directory(key).join(name)
      path.file? ? path : nil
    end
  end
end
