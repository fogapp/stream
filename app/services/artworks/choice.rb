# typed: strict
# frozen_string_literal: true

module Artworks
  # A poster or background chosen by hand (PROPOSAL §7.2): one of TMDB's
  # other pictures for the title, or an uploaded image. Rendered through the
  # same pipeline as any artwork, then locked like a field, so a metadata
  # refresh never puts TMDB's first choice back; resetting unlocks it.
  module Choice
    extend T::Sig

    class Error < StandardError; end

    KINDS = T.let([ Artwork::Kind::Poster, Artwork::Kind::Backdrop ].freeze, T::Array[Artwork::Kind])
    MAX_UPLOAD = T.let(20.megabytes, Integer)

    sig { params(owner: T.any(Movie, Show), kind: Artwork::Kind, path: String).void }
    def self.choose_tmdb(owner, kind, path)
      raise Error, "That isn't one of TMDB's pictures" unless path.match?(%r{\A/[\w.-]+\z})

      artwork = row(owner, kind)
      artwork.assign_attributes(source: Artwork::Source::Tmdb.serialize, source_ref: path)
      Tempfile.create([ "tmdb", File.extname(path) ]) do |file|
        TmdbImages.new.download(path, size: kind.tmdb_size, into: Pathname.new(file.path))
        Publish.call(artwork, source: file.path)
      end
      lock(owner, kind, path: path)
    rescue UpstreamHttpClient::Error, Renderer::Error, ToolRunner::Error => e
      # Nothing was saved: the picture on show stays as it was.
      raise Error, "That picture couldn't be used: #{e.message.truncate(200)}"
    end

    sig { params(owner: T.any(Movie, Show), kind: Artwork::Kind, upload: String, size: Integer).void }
    def self.upload(owner, kind, upload, size:)
      raise Error, "Pictures up to #{MAX_UPLOAD / 1.megabyte} MB" if size > MAX_UPLOAD

      artwork = row(owner, kind)
      artwork.assign_attributes(source: Artwork::Source::Upload.serialize, source_ref: "upload")
      Publish.call(artwork, source: upload)
      lock(owner, kind, path: nil)
    rescue Renderer::Error, ToolRunner::Error
      raise Error, "That file isn't a picture Stream can read"
    end

    # Back to what TMDB gives: unlocked, and the title's details fetched
    # again to find its first choice.
    sig { params(owner: T.any(Movie, Show), kind: Artwork::Kind).void }
    def self.reset(owner, kind)
      owner.update!(locked_fields: owner.locked_fields - [ field(kind) ])
      RefreshMetadataJob.perform_later(owner.class.name.to_s, owner.id)
    end

    sig { params(owner: T.any(Movie, Show), kind: Artwork::Kind).returns(Artwork) }
    def self.row(owner, kind)
      Artwork.find_or_initialize_by(owner: owner, kind: kind.serialize)
    end
    private_class_method :row

    sig { params(owner: T.any(Movie, Show), kind: Artwork::Kind, path: T.nilable(String)).void }
    def self.lock(owner, kind, path:)
      owner.public_send(:"#{field(kind)}=", path) if path
      owner.locked_fields = (owner.locked_fields | [ field(kind) ]).sort
      owner.save!
    end
    private_class_method :lock

    sig { params(kind: Artwork::Kind).returns(String) }
    def self.field(kind) = "#{kind.serialize}_path"
  end
end
