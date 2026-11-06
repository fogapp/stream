# typed: strict
# frozen_string_literal: true

module LiveStreams
  # A stream whose link is a page, not something ffmpeg can open (PROPOSAL
  # §7.8): yt-dlp finds the playlists behind it, which expire, so its source
  # keeps them a while and forgets them when a relay fails on them.
  module Resolver
    extend T::Sig

    # Its link has to be resolved before ffmpeg can read it.
    sig { params(stream: LiveStream).returns(T::Boolean) }
    def self.needed?(stream)
      kind = stream.kind_enum
      case kind
      when LiveStream::Kind::Camera, LiveStream::Kind::Web then false
      when LiveStream::Kind::Youtube, LiveStream::Kind::Mlb then true
      else T.absurd(kind)
      end
    end

    sig { params(stream: LiveStream).returns(Resolved) }
    def self.resolve(stream)
      kind = stream.kind_enum
      case kind
      when LiveStream::Kind::Youtube then YoutubeSource.resolve(stream)
      when LiveStream::Kind::Mlb then MlbSource.resolve(stream)
      when LiveStream::Kind::Camera, LiveStream::Kind::Web then raise ArgumentError, "#{kind.serialize} is read as given"
      else T.absurd(kind)
      end
    end

    sig { params(stream: LiveStream).void }
    def self.forget(stream)
      kind = stream.kind_enum
      case kind
      when LiveStream::Kind::Youtube then YoutubeSource.forget(stream)
      when LiveStream::Kind::Mlb then MlbSource.forget(stream)
      when LiveStream::Kind::Camera, LiveStream::Kind::Web then nil
      else T.absurd(kind)
      end
    end
  end
end
