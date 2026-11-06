# typed: strict
# frozen_string_literal: true

module OfflineDownloadSerializer
  extend T::Sig

  # With a token (only when it's made) come the URLs the service worker
  # fetches: the file, its text subtitles and a poster.
  sig { params(download: OfflineDownload, token: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(download, token: nil)
    playable = download.playable
    file = download.media_file
    heading = PlaybackSessionSerializer.heading(playable)
    base = token && "/media/d/#{token}"
    {
      id: download.id, playable: { type: playable.class.name.to_s.underscore, id: playable.id },
      title: heading[:title], subtitle: heading[:subtitle], back_path: heading[:back_path],
      size: download.size, mime_type: download.mime_type, duration_seconds: file&.duration_seconds,
      optimized: !download.optimized_version_id.nil?, expires_at: download.expires_at, created_at: download.created_at,
      resume_at: resume_at(download),
      # For the offline player: its skip buttons, and what plays next if
      # that's downloaded too.
      markers: MarkerSerializer.list(file),
      skip: PlaybackSessionSerializer.skip_for(download.profile, playable),
      next_episode_id: playable.is_a?(Episode) ? PlaybackSessionSerializer.following_episode(playable)&.id : nil,
      file_url: base && "#{base}/file.#{download.extension}",
      poster_url: base && poster_url(playable),
      subtitles: base && file ? subtitles(file, base) : []
    }
  end

  sig { params(download: OfflineDownload).returns(Float) }
  def self.resume_at(download)
    state = WatchState.find_by(profile_id: download.profile_id, playable: download.playable)
    state.nil? || state.completed? ? 0.0 : state.position_seconds.to_f
  end

  # Text tracks only, as WebVTT: what a <video> element shows on its own.
  sig { params(file: MediaFile, base: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.subtitles(file, base)
    Subtitles::Tracks.for(file).select { |track| track.format == Subtitles::Tracks::Format::Vtt || track.format == Subtitles::Tracks::Format::Ass }
      .map do |track|
        { id: track.id, language: track.language, label: [ track.language, track.title ].compact.join(" · ").presence || "Subtitles",
          forced: track.forced, url: "#{base}/subtitles/#{track.id}.vtt" }
      end
  end

  sig { params(playable: T.untyped).returns(T.nilable(String)) }
  def self.poster_url(playable)
    owners =
      case playable
      when Episode then [ [ playable, Artwork::Kind::Still ], [ playable.show, Artwork::Kind::Poster ] ]
      when Movie then [ [ playable, Artwork::Kind::Poster ] ]
      else [ [ playable, Artwork::Kind::Thumb ], [ playable, Artwork::Kind::Poster ] ]
      end
    owners.each do |owner, kind|
      next if owner.nil?

      artwork = Artwork.ready.find_by(owner: owner, kind: kind.serialize)
      return ArtworkSerializer.image_json(artwork)[:src] if artwork
    end
    nil
  end
end
