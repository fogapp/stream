# typed: strict
# frozen_string_literal: true

module ArtworkSerializer
  extend T::Sig

  Index = T.type_alias { T::Hash[[ String, String ], T::Hash[String, Artwork]] }

  # Every ready artwork for a page of owners in one query, keyed for lookup.
  sig { params(owners: T::Array[ApplicationRecord]).returns(Index) }
  def self.index(owners)
    return {} if owners.empty?

    by_type = owners.group_by { |owner| owner.class.name.to_s }
    scope = by_type.map { |type, list| Artwork.ready.where(owner_type: type, owner_id: list.map(&:id)) }.reduce(:or)
    scope.each_with_object({}) do |artwork, index|
      (index[[ artwork.owner_type, artwork.owner_id ]] ||= {})[artwork.kind] = artwork
    end
  end

  # { poster: {...}, backdrop: {...} } for one owner, from an index.
  sig { params(index: Index, owner: ApplicationRecord).returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
  def self.images(index, owner)
    index.fetch([ owner.class.name.to_s, owner.id.to_s ], {}).transform_values { |artwork| image_json(artwork) }
  end

  sig { params(artwork: Artwork).returns(T::Hash[Symbol, T.untyped]) }
  def self.image_json(artwork)
    widths = artwork.rendered_widths.sort
    {
      src: ArtworkUrl.for(artwork, widths[widths.size / 2] || widths.last || 0),
      srcset: widths.map { |width| "#{ArtworkUrl.for(artwork, width)} #{width}w" }.join(", "),
      width: artwork.width, height: artwork.height, placeholder: artwork.placeholder, color: artwork.color
    }
  end
end
