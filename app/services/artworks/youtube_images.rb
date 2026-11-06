# typed: strict
# frozen_string_literal: true

module Artworks
  # A tracked channel's avatar and banner, from YouTube's image hosts
  # (PROPOSAL §5.4) — only those hosts, whatever URL yt-dlp reported.
  class YoutubeImages
    extend T::Sig
    include UpstreamHttpClient

    HOSTS = T.let(%w[yt3.ggpht.com yt3.googleusercontent.com i.ytimg.com].to_set.freeze, T::Set[String])
    MAX_BYTES = T.let(15 * 1024 * 1024, Integer)

    class Refused < UpstreamHttpClient::Error; end

    sig { override.returns(String) }
    def service_name = "YouTube images"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = UpstreamHttpClient::Error

    sig { params(url: String, into: Pathname).void }
    def download(url, into:)
      uri = URI.parse(url)
      raise Refused, "not a YouTube image: #{url.truncate(80)}" unless uri.scheme == "https" && HOSTS.include?(uri.host.to_s)

      http_get_file(url, into: into, max_bytes: MAX_BYTES)
    rescue URI::InvalidURIError
      raise Refused, "not a URL"
    end

    # Renders a channel's pictures, or an identified video's thumbnail, from
    # YouTube for the kinds nothing on disk has already pictured.
    sig { params(owner: T.any(Channel, Video)).void }
    def self.sync(owner)
      wanted = case owner
      when Channel then { Artwork::Kind::Profile => owner.avatar_url, Artwork::Kind::Backdrop => owner.banner_url }
      when Video then { Artwork::Kind::Thumb => owner.thumbnail_url }
      else T.absurd(owner)
      end
      wanted.each do |kind, url|
        next if url.blank?

        artwork = Artwork.find_or_initialize_by(owner: owner, kind: kind.serialize)
        next if artwork.ready? && artwork.source_enum == Artwork::Source::Local
        same = artwork.source_enum == Artwork::Source::Youtube && artwork.source_ref == url
        next if same && (artwork.ready? || artwork.given_up?)

        artwork.update!(source: Artwork::Source::Youtube.serialize, source_ref: url, **(same ? {} : { consecutive_failures: 0 }))
        Tempfile.create([ "youtube", ".img" ]) do |file|
          new.download(url.to_s, into: Pathname.new(file.path))
          Publish.call(artwork, source: file.path)
        end
      rescue UpstreamHttpClient::Error, Renderer::Error, ToolRunner::Error => e
        artwork&.record_failure!(e)
      end
    end
  end
end
