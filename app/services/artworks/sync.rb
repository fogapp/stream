# typed: strict
# frozen_string_literal: true

module Artworks
  # Brings one owner's artwork rows in line with the image paths its
  # metadata names, rendering what's new or changed (PROPOSAL §5.5). A
  # failed render records its error on the row and leaves any previous
  # render in place (CLAUDE.md invariant 5).
  class Sync
    extend T::Sig

    Owner = T.type_alias { T.any(Movie, Show, Season, Episode, Person, Collection, CollectionPart) }

    sig { params(owner: Owner).void }
    def initialize(owner)
      @owner = owner
    end

    sig { void }
    def call
      wanted.each { |kind, path| ensure_rendered(kind, path) }
    end

    # Kinds this owner should have, and the TMDB path for each.
    sig { returns(T::Hash[Artwork::Kind, String]) }
    def wanted
      owner = @owner
      paths =
        case owner
        when Movie, Show
          { Artwork::Kind::Poster => owner.poster_path, Artwork::Kind::Backdrop => owner.backdrop_path,
            Artwork::Kind::Logo => owner.logo_path }
        when Season then { Artwork::Kind::Poster => owner.poster_path }
        when Episode then { Artwork::Kind::Still => owner.still_path }
        when Person then { Artwork::Kind::Profile => owner.profile_path }
        when Collection then { Artwork::Kind::Poster => owner.poster_path, Artwork::Kind::Backdrop => owner.backdrop_path }
        when CollectionPart then { Artwork::Kind::Poster => owner.poster_path }
        else T.absurd(owner)
        end
      # A picture a person chose (in Plex, say) is locked like any field.
      locked = owner.respond_to?(:locked_fields) ? T.unsafe(owner).locked_fields : []
      paths.compact.reject { |kind, path| path.blank? || locked.include?("#{kind.serialize}_path") }
    end

    private

    sig { params(kind: Artwork::Kind, path: String).void }
    def ensure_rendered(kind, path)
      artwork = Artwork.find_or_initialize_by(owner: @owner, kind: kind.serialize) do |row|
        row.source = Artwork::Source::Tmdb.serialize
        row.source_ref = path
      end
      changed = artwork.new_record? || artwork.source_ref != path || artwork.source_enum != Artwork::Source::Tmdb
      return if !changed && artwork.ready?
      return if !changed && artwork.given_up?

      artwork.assign_attributes(source: Artwork::Source::Tmdb.serialize, source_ref: path)
      artwork.consecutive_failures = 0 if changed
      artwork.save!
      Tempfile.create([ "tmdb", File.extname(path) ]) do |file|
        TmdbImages.new.download(path, size: kind.tmdb_size, into: Pathname.new(file.path))
        Publish.call(artwork, source: file.path, alpha: kind == Artwork::Kind::Logo)
      end
    rescue UpstreamHttpClient::Error, Renderer::Error, ToolRunner::Error => e
      artwork&.record_failure!(e)
    end
  end
end
