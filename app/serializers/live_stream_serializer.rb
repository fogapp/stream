# typed: strict
# frozen_string_literal: true

# A live stream (PROPOSAL §7.8). Never its URL: `source` is scheme, host and
# port. What went wrong and the certificate switch are for admins.
module LiveStreamSerializer
  extend T::Sig

  sig { params(stream: LiveStream, admin: T::Boolean).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(stream, admin: false)
    {
      id: stream.id, type: "live_stream", name: stream.name, kind: stream.kind_enum, feed: stream.feed_enum, library_id: stream.library_id,
      description: stream.description, content_rating: stream.content_rating,
      source: stream.source, status: stream.status_enum, last_seen_at: stream.last_seen_at,
      still_url: LiveStreams::StillUrl.for(stream),
      tracks: tracks_json(stream.media_streams.to_a)
    }.merge(admin ? admin_json(stream) : {})
  end

  sig { params(stream: LiveStream).returns(T::Hash[Symbol, T.untyped]) }
  def self.admin_json(stream)
    {
      trust_certificate: stream.trust_certificate, keep_connected: stream.keep_connected, last_error: stream.last_error, last_error_at: stream.last_error_at,
      consecutive_failures: stream.consecutive_failures, probed_at: stream.probed_at, container: stream.container
    }
  end

  sig { params(streams: T::Array[T.untyped]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.tracks_json(streams)
    streams.filter_map do |track|
      row = track.is_a?(MediaStream) ? track.attributes.symbolize_keys : track
      kind = row[:kind].to_s
      next nil unless %w[video audio].include?(kind)

      { kind: kind, codec: row[:codec], width: row[:width], height: row[:height], frame_rate: row[:frame_rate],
        channels: row[:channels] }
    end
  end
end
