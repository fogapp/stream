# typed: strict
# frozen_string_literal: true

module Artworks
  # Pictures that sit beside the media (PROPOSAL §5.4): a video's thumbnail
  # (yt-dlp --write-thumbnail names it after the video), a channel folder's
  # avatar and banner.
  class Local
    extend T::Sig

    IMAGE_EXTENSIONS = T.let(%w[.jpg .jpeg .png .webp].freeze, T::Array[String])
    AVATAR_NAMES = T.let(%w[avatar poster folder].freeze, T::Array[String])
    BANNER_NAMES = T.let(%w[banner backdrop fanart].freeze, T::Array[String])

    sig { params(owner: T.any(Channel, Video)).void }
    def initialize(owner)
      @owner = owner
    end

    sig { void }
    def call
      wanted.each { |kind, path| publish(kind, path) }
    end

    sig { returns(T::Hash[Artwork::Kind, String]) }
    def wanted
      owner = @owner
      case owner
      when Video
        file = owner.best_file
        return {} if file.nil?

        base = file.path.delete_suffix(File.extname(file.path))
        thumb = IMAGE_EXTENSIONS.map { |ext| "#{base}#{ext}" }.find { |path| File.file?(path) }
        thumb ? { Artwork::Kind::Thumb => thumb } : {}
      when Channel
        folder = channel_folder(owner)
        return {} if folder.nil?

        { Artwork::Kind::Profile => first_image(folder, AVATAR_NAMES), Artwork::Kind::Backdrop => first_image(folder, BANNER_NAMES) }
          .compact
      else T.absurd(owner)
      end
    end

    private

    sig { params(channel: Channel).returns(T.nilable(String)) }
    def channel_folder(channel)
      library = channel.library
      library&.roots&.map { |root| File.join(root, channel.folder) }&.find { |path| File.directory?(path) }
    end

    sig { params(folder: String, names: T::Array[String]).returns(T.nilable(String)) }
    def first_image(folder, names)
      names.product(IMAGE_EXTENSIONS).map { |name, ext| File.join(folder, "#{name}#{ext}") }.find { |path| File.file?(path) }
    end

    sig { params(kind: Artwork::Kind, path: String).void }
    def publish(kind, path)
      stamp = "#{path}@#{File.mtime(path).to_i}"
      artwork = Artwork.find_or_initialize_by(owner: @owner, kind: kind.serialize)
      same = artwork.source_enum == Artwork::Source::Local && artwork.source_ref == stamp
      return if same && (artwork.ready? || artwork.given_up?)

      artwork.update!(source: Artwork::Source::Local.serialize, source_ref: stamp, **(same ? {} : { consecutive_failures: 0 }))
      Publish.call(artwork, source: path)
    rescue Renderer::Error, ToolRunner::Error, SystemCallError => e
      artwork&.record_failure!(e)
    end
  end
end
